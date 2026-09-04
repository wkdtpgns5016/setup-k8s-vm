#!/usr/bin/env bash
set -e

echo ">>> [Metrics Server] 배포 시작..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 사설 인증서 통신 허용 플래그 주입
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}
]'

echo ">>> [Metrics Server] 기동 대기 중..."
kubectl rollout status deployment metrics-server -n kube-system --timeout=120s

echo ">>> [Metrics Server] 설치 완료! (메트릭 수집까지 약 1분 소요)"
