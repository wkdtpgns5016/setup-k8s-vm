#!/usr/bin/env bash
set -e

# Kubernetes v1.34 지원 (metrics-server chart 3.14.x = app v0.9.x, k8s 1.34+ 호환)
CHART_VERSION="3.14.0"

echo ">>> [Metrics Server] Helm Repo 등록 및 업데이트..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

echo ">>> [Metrics Server] Helm 표준 배포 (--kubelet-insecure-tls 주입)..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "${CHART_VERSION}" \
  --namespace kube-system \
  --set args="{--kubelet-insecure-tls}"

echo ">>> [Metrics Server] 파드 정상 기동 대기 중..."
kubectl rollout status deployment metrics-server -n kube-system --timeout=60s

echo ">>> [Metrics Server] 설치 완료!"