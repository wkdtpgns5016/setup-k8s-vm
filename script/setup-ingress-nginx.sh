#!/usr/bin/env bash
set -e

# Kubernetes v1.34 지원 (ingress-nginx chart 4.15.x = controller v1.15.x, k8s 1.31~1.35 테스트됨)
CHART_VERSION="4.15.1"

# 마스터를 제외한 워커 노드 이름 자동 탐색
WORKER_NODE_NAME=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')

if [ -z "$WORKER_NODE_NAME" ]; then
  echo "에러: 클러스터에서 워커 노드를 찾을 수 없습니다."
  exit 1
fi

echo ">>> 탐색된 워커 노드: ${WORKER_NODE_NAME}"

echo ">>> [Ingress-Nginx] Helm Repo 등록 및 업데이트..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

echo ">>> [Ingress-Nginx] Helm 표준 배포 (Webhook 비활성화 + hostNetwork)..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "${CHART_VERSION}" \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.nodeSelector."kubernetes\.io/hostname"="${WORKER_NODE_NAME}" \
  --set controller.updateStrategy.type=Recreate \
  --set controller.admissionWebhooks.enabled=false \
  --set controller.service.type=ClusterIP

echo ">>> [Ingress-Nginx] 컨트롤러 파드 기동 대기 중..."
kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=60s

echo ">>> [Ingress-Nginx] 설치 완료! (${WORKER_NODE_NAME} 노드 80/443 포트 바인딩)"