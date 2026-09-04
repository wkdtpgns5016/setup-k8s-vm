#!/usr/bin/env bash
set -e

# 마스터/컨트롤 플레인 역할을 제외한 워커 노드 이름 자동 탐색
WORKER_NODE_NAME=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')

if [ -z "$WORKER_NODE_NAME" ]; then
  echo "에러: 클러스터에서 워커 노드를 찾을 수 없습니다."
  exit 1
fi

echo ">>> 탐색된 워커 노드: ${WORKER_NODE_NAME}"

echo ">>> [Ingress-Nginx] 공식 매니페스트 적용 중..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml

# Admission Webhook 검증 리소스 제거
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found=true

# 동적으로 찾은 워커 노드 고정 + hostNetwork 활성화 + 웹훅 볼륨 제거
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' -p="[
  {\"op\": \"add\", \"path\": \"/spec/template/spec/nodeSelector\", \"value\": {\"kubernetes.io/hostname\": \"${WORKER_NODE_NAME}\"}},
  {\"op\": \"add\", \"path\": \"/spec/template/spec/hostNetwork\", \"value\": true},
  {\"op\": \"remove\", \"path\": \"/spec/template/spec/volumes/0\"},
  {\"op\": \"remove\", \"path\": \"/spec/template/spec/containers/0/volumeMounts/0\"}
]"

echo ">>> [Ingress-Nginx] 컨트롤러 파드 기동 대기 중..."
kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=120s

echo ">>> [Ingress-Nginx] 설치 완료! (${WORKER_NODE_NAME} 노드 80 포트 바인딩)"
