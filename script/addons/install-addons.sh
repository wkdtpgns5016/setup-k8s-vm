#!/usr/bin/env bash
set -e

# 마스터 노드에서, 워커 조인 완료 후 실행하는 애드온 설치기
# 기본값은 전부 설치: metrics-server -> ingress-nginx -> argocd -> monitoring
#   (ingress-nginx 가 argocd / monitoring 보다 먼저여야 함)
# 특정 애드온만 골라서 설치할 수도 있음 (실행 시 메뉴에서 선택)
# 이미 설치된 애드온(Helm 릴리스 존재)은 건너뜀

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-ingress-ip.sh
source "${SCRIPT_DIR}/lib-ingress-ip.sh"

echo "=== 0. 사전 점검 ==="

if ! command -v helm &> /dev/null; then
  echo "에러: helm 이 설치되어 있지 않습니다. setup-k8s-master.sh 를 먼저 실행하세요."
  exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
  echo "에러: kubectl 로 클러스터에 접근할 수 없습니다. (~/.kube/config 확인)"
  exit 1
fi

WORKER_COUNT=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | wc -l | tr -d ' ')
if [ "${WORKER_COUNT:-0}" -lt 1 ]; then
  echo "에러: 워커 노드가 없습니다. 워커 노드 조인 후 다시 실행하세요."
  echo "      (ingress-nginx / argocd 는 워커 노드에 배치됩니다)"
  exit 1
fi
echo "워커 노드 ${WORKER_COUNT}개 확인됨."

echo ""
echo "=== 0-1. 설치할 애드온 선택 ==="
echo "1) Ingress-Nginx 만"
echo "2) Argo CD 만"
echo "3) Metrics Server 만"
echo "4) Monitoring 만"
echo "5) 전부 설치 (기본값)"
read -rp "번호를 선택하세요 [기본값: 5]: " ADDON_CHOICE
ADDON_CHOICE="${ADDON_CHOICE:-5}"
case "$ADDON_CHOICE" in
  1|2|3|4|5) ;;
  *)
    echo "잘못된 입력입니다. 기본값(전부 설치)으로 진행합니다."
    ADDON_CHOICE=5
    ;;
esac

echo ""
echo "=== 0-2. Ingress 접속 주소 방식 확인 ==="
if [ "$ADDON_CHOICE" = 2 ] || [ "$ADDON_CHOICE" = 4 ] || [ "$ADDON_CHOICE" = 5 ]; then
  # ArgoCD / 모니터링 등 nip.io 기반 ingress hostname 을 쓰는 애드온에서 공통으로 사용.
  # 여기서 한 번만 물어보고 환경 변수로 하위 애드온 스크립트(bash 서브프로세스)에 전달해
  # 애드온마다 중복으로 묻지 않도록 함. (개별 스크립트를 단독 실행하면 그때는 각자 다시 물어봄)
  resolve_ingress_ip
  export TAILSCALE_ANSWERED
  export TAILSCALE_INGRESS_IP
else
  echo "[SKIP] 선택한 애드온은 ingress 주소가 필요 없습니다."
fi

# release / namespace / 설치 스크립트
run_addon() {
  local name="$1" release="$2" namespace="$3" script="$4"
  echo ""
  echo "=== ${name} ==="
  if helm status "$release" -n "$namespace" &> /dev/null; then
    echo "[SKIP] Helm 릴리스 '${release}' (ns: ${namespace}) 가 이미 존재합니다."
    return 0
  fi
  echo ">>> ${script} 실행..."
  bash "${SCRIPT_DIR}/${script}"
}

case "$ADDON_CHOICE" in
  1) run_addon "Ingress-Nginx"  ingress-nginx         ingress-nginx  setup-ingress-nginx.sh ;;
  2) run_addon "Argo CD"        argocd                argocd         setup-argocd.sh ;;
  3) run_addon "Metrics Server" metrics-server        kube-system    setup-metrics-server.sh ;;
  4) run_addon "Monitoring"     kube-prometheus-stack monitoring     setup-monitoring.sh ;;
  5)
    run_addon "1. Metrics Server" metrics-server        kube-system    setup-metrics-server.sh
    run_addon "2. Ingress-Nginx"  ingress-nginx         ingress-nginx  setup-ingress-nginx.sh
    run_addon "3. Argo CD"        argocd                argocd         setup-argocd.sh
    run_addon "4. Monitoring"     kube-prometheus-stack monitoring     setup-monitoring.sh
    ;;
esac

echo ""
echo "=================================================================="
echo " [애드온 설치 완료]"
echo ""
if [ "$ADDON_CHOICE" = 3 ] || [ "$ADDON_CHOICE" = 5 ]; then
  kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server --no-headers 2>/dev/null | sed 's/^/  metrics-server: /' || true
fi
if [ "$ADDON_CHOICE" = 1 ] || [ "$ADDON_CHOICE" = 5 ]; then
  kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | sed 's/^/  ingress-nginx : /' || true
fi
if [ "$ADDON_CHOICE" = 2 ] || [ "$ADDON_CHOICE" = 5 ]; then
  echo ""
  echo "  ArgoCD 접속 정보:"
  ARGO_HOST=$(kubectl get ingress argocd-server -n argocd -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
  ARGO_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  echo "    URL      : http://${ARGO_HOST:-<확인필요>}"
  echo "    ID       : admin"
  echo "    Password : ${ARGO_PW:-(변경됨 또는 시크릿 삭제됨)}"
fi
if [ "$ADDON_CHOICE" = 4 ] || [ "$ADDON_CHOICE" = 5 ]; then
  echo ""
  echo "  Grafana 접속 정보:"
  GRAFANA_HOST=$(kubectl get ingress -n monitoring -o jsonpath='{.items[?(@.metadata.name=="kube-prometheus-stack-grafana")].spec.rules[0].host}' 2>/dev/null || true)
  GRAFANA_PW=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  echo "    URL      : http://${GRAFANA_HOST:-<확인필요>}"
  echo "    ID       : admin"
  echo "    Password : ${GRAFANA_PW:-(변경됨 또는 secret 없음)}"
fi
echo "=================================================================="
