#!/usr/bin/env bash
set -e

# Kubernetes v1.34 지원 (argo-cd chart 10.7.x = Argo CD v3.x, k8s 1.31+ 호환)
CHART_VERSION="10.7.1"
NAMESPACE="argocd"

echo ">>> [Argo CD] Ingress 진입점(워커 노드) IP 탐지..."
INGRESS_IP=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')

if [ -z "$INGRESS_IP" ]; then
  echo "에러: 워커 노드를 찾을 수 없습니다. 먼저 워커 노드를 조인하고 setup-ingress-nginx.sh 를 실행하세요."
  exit 1
fi

# nip.io: <이름>.<IP>.nip.io 는 공인 와일드카드 DNS 로 해당 IP 를 반환 (hosts 수정 불필요)
ARGOCD_HOST="argocd.${INGRESS_IP}.nip.io"
echo ">>> [Argo CD] 접속 도메인: ${ARGOCD_HOST}"

echo ">>> [Argo CD] Helm Repo 등록 및 업데이트..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo ">>> [Argo CD] Helm 배포 (insecure 모드 + ingress-nginx)..."
# server.insecure=true : Argo CD 서버가 TLS 종료를 하지 않고 평문 HTTP 로 서비스 (ingress-nginx 가 앞단 처리)
# backend-protocol=HTTP : nginx 가 백엔드로 평문 HTTP 로 프록시
helm upgrade --install argocd argo/argo-cd \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP \
  --set server.ingress.enabled=true \
  --set server.ingress.ingressClassName=nginx \
  --set server.ingress.hostname="${ARGOCD_HOST}" \
  --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/backend-protocol"=HTTP

echo ">>> [Argo CD] 서버 파드 기동 대기 중..."
kubectl rollout status deployment argocd-server -n "${NAMESPACE}" --timeout=180s

echo ">>> [Argo CD] 초기 admin 비밀번호 조회 대기 중..."
for _ in $(seq 1 30); do
  ADMIN_PW=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "$ADMIN_PW" ] && break
  sleep 2
done

echo ""
echo "=================================================================="
echo " [Argo CD 설치 완료]"
echo ""
echo "  URL      : http://${ARGOCD_HOST}"
echo "  ID       : admin"
if [ -n "$ADMIN_PW" ]; then
  echo "  Password : ${ADMIN_PW}"
  echo ""
  echo "  * 최초 로그인 후 비밀번호 변경 및 아래 시크릿 삭제 권장:"
  echo "    kubectl -n ${NAMESPACE} delete secret argocd-initial-admin-secret"
else
  echo "  Password : (조회 실패) 아래 명령으로 직접 확인하세요."
  echo "    kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
fi
echo ""
echo "  CLI 로그인 (평문 HTTP + L7 프록시이므로 --plaintext --grpc-web 필요):"
echo "    argocd login ${ARGOCD_HOST} --plaintext --grpc-web --username admin"
echo "=================================================================="
