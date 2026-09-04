#!/usr/bin/env bash
set -e

# 마스터 노드에서 실행 (kube-controller-manager / kube-scheduler bind-address 패치 때문)
# kube-prometheus-stack (Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics)
# VM 랩 기준 경량 프로파일: retention 3d / scrape 60s / Alertmanager 비활성 / 리소스 상한 지정 / 스토리지 emptyDir

# Kubernetes v1.34 지원 (kube-prometheus-stack 89.x)
CHART_VERSION="89.2.0"
NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="${SCRIPT_DIR}/dashboards"

echo "=== 0. 사전 점검 ==="
command -v helm &> /dev/null || { echo "에러: helm 이 없습니다. setup-k8s-master.sh 를 먼저 실행하세요."; exit 1; }
kubectl cluster-info &> /dev/null || { echo "에러: kubectl 로 클러스터에 접근할 수 없습니다."; exit 1; }
kubectl get ingressclass nginx &> /dev/null || {
  echo "에러: IngressClass 'nginx' 가 없습니다. setup-ingress-nginx.sh 를 먼저 실행하세요."; exit 1;
}

if helm status "$RELEASE" -n "$NAMESPACE" &> /dev/null; then
  echo "[SKIP] Helm 릴리스 '${RELEASE}' (ns: ${NAMESPACE}) 가 이미 존재합니다."
  exit 0
fi

echo "=== 1. Ingress 진입점(워커 노드) IP 탐지 ==="
INGRESS_IP=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
[ -n "$INGRESS_IP" ] || { echo "에러: 워커 노드를 찾을 수 없습니다."; exit 1; }

GRAFANA_HOST="grafana.${INGRESS_IP}.nip.io"
PROM_HOST="prometheus.${INGRESS_IP}.nip.io"
echo "Grafana    : http://${GRAFANA_HOST}"
echo "Prometheus : http://${PROM_HOST}"

echo ""
echo "=== 2. kubeadm 컴포넌트 메트릭 bind-address 패치 ==="
MANIFEST_DIR="/etc/kubernetes/manifests"
if [ ! -f "${MANIFEST_DIR}/kube-controller-manager.yaml" ]; then
  echo "[SKIP] ${MANIFEST_DIR} 접근 불가 (마스터 노드가 아님)."
  echo "       kube-controller-manager / kube-scheduler 타겟이 DOWN 으로 보일 수 있습니다."
elif sudo grep -lq -- '--bind-address=127.0.0.1' \
      "${MANIFEST_DIR}/kube-controller-manager.yaml" "${MANIFEST_DIR}/kube-scheduler.yaml" 2>/dev/null; then
  echo ">>> kube-controller-manager / kube-scheduler --bind-address 를 0.0.0.0 으로 변경..."
  sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' \
    "${MANIFEST_DIR}/kube-controller-manager.yaml" "${MANIFEST_DIR}/kube-scheduler.yaml"
  echo "    static pod 자동 재기동 (약 30초 소요)"
else
  echo "[SKIP] kube-controller-manager / kube-scheduler 이미 0.0.0.0 바인딩."
fi

CUR_MBA=$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null \
  | grep -E '^[[:space:]]*metricsBindAddress:' | awk '{print $2}' | tr -d '"' || true)
if [ "$CUR_MBA" != "0.0.0.0:10249" ]; then
  echo ">>> kube-proxy metricsBindAddress 를 0.0.0.0:10249 로 변경..."
  kubectl -n kube-system get cm kube-proxy -o yaml \
    | sed 's|metricsBindAddress: .*|metricsBindAddress: "0.0.0.0:10249"|' \
    | kubectl apply -f - > /dev/null
  kubectl -n kube-system rollout restart ds kube-proxy > /dev/null
  echo "    kube-proxy DaemonSet 롤아웃 재시작됨."
else
  echo "[SKIP] kube-proxy metricsBindAddress 이미 0.0.0.0:10249."
fi

echo ""
echo "=== 3. Helm Repo 등록 및 배포 ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set alertmanager.enabled=false \
  --set kubeEtcd.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=3d \
  --set prometheus.prometheusSpec.scrapeInterval=60s \
  --set prometheus.prometheusSpec.evaluationInterval=60s \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=300Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=900Mi \
  --set prometheusOperator.resources.requests.memory=64Mi \
  --set prometheusOperator.resources.limits.memory=200Mi \
  --set grafana.persistence.enabled=false \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.memory=400Mi \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=nginx \
  --set grafana.ingress.hosts[0]="${GRAFANA_HOST}" \
  --set grafana.ingress.path=/ \
  --set grafana.ingress.pathType=Prefix \
  --set prometheus.ingress.enabled=true \
  --set prometheus.ingress.ingressClassName=nginx \
  --set prometheus.ingress.hosts[0]="${PROM_HOST}" \
  --set prometheus.ingress.paths[0]=/ \
  --set prometheus.ingress.pathType=Prefix \
  --set prometheus-node-exporter.resources.requests.memory=32Mi \
  --set prometheus-node-exporter.resources.limits.memory=64Mi \
  --set kube-state-metrics.resources.requests.memory=64Mi \
  --set kube-state-metrics.resources.limits.memory=200Mi

echo ""
echo "=== 4. Grafana 대시보드 프로비저닝 ==="
# script/dashboards/**/*.json 를 ConfigMap 으로 등록.
#   label grafana_dashboard=1 -> Grafana 사이드카가 자동 로드 (기본 대시보드와 같은 위치)
#   폴더 분리는 하지 않음: foldersFromFilesStructure + '/' 포함 폴더명이 kube-prometheus-stack
#   기본 대시보드와 충돌해 중첩/빈 폴더가 생기므로. 대시보드는 이름으로 구분 (검색/즐겨찾기).
load_dashboards() {
  local dir="$1" f base cm
  [ -d "$dir" ] || { echo "  [SKIP] ${dir} 없음"; return 0; }
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .json)
    cm="grafana-dashboard-${base}"
    kubectl -n "$NAMESPACE" create configmap "$cm" \
      --from-file="${base}.json=${f}" --dry-run=client -o yaml \
      | kubectl apply -f - > /dev/null
    kubectl -n "$NAMESPACE" label configmap "$cm" grafana_dashboard=1 --overwrite > /dev/null
    echo "  로드: ${base}"
  done
}
load_dashboards "${DASHBOARD_DIR}/kubernetes"
load_dashboards "${DASHBOARD_DIR}/application"

echo ""
echo "=== 5. 기동 대기 ==="
kubectl -n "$NAMESPACE" rollout status deploy/${RELEASE}-operator --timeout=180s
kubectl -n "$NAMESPACE" rollout status deploy/${RELEASE}-grafana --timeout=180s

echo ">>> Prometheus StatefulSet 생성 대기..."
for _ in $(seq 1 30); do
  kubectl -n "$NAMESPACE" get statefulset "prometheus-${RELEASE}-prometheus" &> /dev/null && break
  sleep 2
done
kubectl -n "$NAMESPACE" rollout status statefulset/"prometheus-${RELEASE}-prometheus" --timeout=300s

GRAFANA_PW=$(kubectl -n "$NAMESPACE" get secret "${RELEASE}-grafana" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)

echo ""
echo "=================================================================="
echo " [모니터링 스택 설치 완료]"
echo ""
echo "  Grafana    : http://${GRAFANA_HOST}"
echo "    ID / PW  : admin / ${GRAFANA_PW:-(secret 확인 필요)}"
echo "  Prometheus : http://${PROM_HOST}"
echo ""
echo "  프로파일   : retention 3d / scrape 60s / Alertmanager 비활성 / 스토리지 emptyDir"
echo "  대시보드   : 'Kubernetes / Views' (dotdc) + 'Application' (app-overview)"
echo "               앱 배포 후 Application 대시보드에서 namespace/workload 선택"
echo "  타겟 상태  : http://${PROM_HOST}/targets  또는"
echo "    kubectl -n ${NAMESPACE} get servicemonitor"
echo ""
echo "  * Grafana 비밀번호 변경 권장:"
echo "    kubectl -n ${NAMESPACE} exec deploy/${RELEASE}-grafana -- grafana cli admin reset-admin-password <새비밀번호>"
echo "=================================================================="
