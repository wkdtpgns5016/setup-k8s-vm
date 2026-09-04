#!/usr/bin/env bash
set -e

# 마스터/컨트롤 플레인 역할을 제외한 워커 노드 이름 자동 탐색
WORKER_NODE_NAME=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')

if [ -z "$WORKER_NODE_NAME" ]; then
  echo "에러: 클러스터에서 워커 노드를 찾을 수 없습니다."
  exit 1
fi

echo ">>> 탐색된 워커 노드: ${WORKER_NODE_NAME}"

echo ">>> [Ingress-Nginx] 공식 매니페스트 (v1.12.0) 적용 중..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml

echo ">>> [Admission Webhook 및 불필요한 잡(Job) 파드 완전 제거]"
# 1. API Server의 Ingress 검증 차단 방지 (웹훅 설정 삭제)
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found=true

# 2. 인증서 생성/패치를 시도하다 CrashLoopBackOff에 빠지는 잡 및 파드 완전 정리
kubectl delete job -n ingress-nginx --all --ignore-not-found=true
kubectl delete pod -n ingress-nginx -l app.kubernetes.io/component=admission-webhook --force --grace-period=0 2>/dev/null || true

# 동적으로 찾은 워커 노드 지정 및 hostNetwork 활성화
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --patch "
spec:
  template:
    spec:
      hostNetwork: true
      nodeSelector:
        kubernetes.io/hostname: ${WORKER_NODE_NAME}
"

echo ">>> [Ingress-Nginx] 컨트롤러 파드 기동 대기 중..."
kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=120s

echo ">>> [Ingress-Nginx] 설치 완료! (${WORKER_NODE_NAME} 노드 80/443 포트 바인딩)"