#!/usr/bin/env bash
set -e

IFACE="enp0s8"
# 노드 네트워크(192.168.x)와 겹치지 않는 대역 사용 (라우팅 충돌 방지)
POD_CIDR="10.244.0.0/16"
# Kubernetes v1.34 지원 (Calico v3.32 는 k8s 1.34/1.35/1.36 에 대해 테스트됨)
CALICO_VERSION="v3.32.2"

echo "=== 1. Host-Only IP 감지 ==="
MASTER_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

if [ -z "$MASTER_IP" ]; then
  echo "에러: ${IFACE} 인터페이스의 IP를 확인할 수 없습니다."
  exit 1
fi
echo "Master IP: ${MASTER_IP} (${IFACE})"

# 2. 이미 마스터 노드로 동작 중인지 확인
if [ -f "/etc/kubernetes/admin.conf" ]; then
  echo ""
  echo "[PASS] 이미 Kubernetes 컨트롤 플레인이 구성되어 있습니다."
  
  JOIN_CMD=$(sudo kubeadm token create --print-join-command 2>/dev/null || true)
  if [ -n "$JOIN_CMD" ]; then
    echo "=================================================================="
    echo " [기존 클러스터 토큰 갱신]"
    echo " 워커 노드 조인 명령어:"
    echo " sudo $JOIN_CMD"
    echo "=================================================================="
  fi
  exit 0
fi

# 3. 신규 초기화 및 실패 시 자동 롤백 핸들러
cleanup_on_init_fail() {
  local code=$?
  echo ""
  echo "[Rollback] kubeadm 초기화 실패 (코드: ${code}). 클러스터를 리셋합니다..."
  sudo kubeadm reset -f || true
  sudo rm -rf /etc/cni/net.d "$HOME/.kube"
  exit "$code"
}
trap cleanup_on_init_fail ERR

echo ""
echo "=== 2. kubeadm 초기화 시작 (Kubernetes v1.34) ==="
sudo kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}"

echo ""
echo "=== 3. kubectl config 설정 ==="
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo ""
echo "=== 4. Calico CNI (${CALICO_VERSION}) 배포 ==="
curl -sSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o /tmp/calico.yaml

# calico.yaml 기본 IP 풀은 192.168.0.0/16 으로 하드코딩되어 있음.
# 최초 기동 전에 매니페스트에서 POD_CIDR 로 맞춰줘야 반영된다 (기동 후 env 변경은 IP 풀에 소급 적용 안 됨).
sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' /tmp/calico.yaml
sed -i 's|#   value: "192.168.0.0/16"|  value: "'"${POD_CIDR}"'"|' /tmp/calico.yaml

# CRD 크기가 커서 client-side apply 시 annotation 256KB 제한에 걸릴 수 있으므로 server-side 적용
kubectl apply --server-side --force-conflicts -f /tmp/calico.yaml
rm -f /tmp/calico.yaml

# VirtualBox Dual-NIC 환경 대응: 자동 감지 인터페이스를 enp0s8 로 고정
echo ">>> calico-node DaemonSet 생성 대기 중..."
kubectl -n kube-system rollout status ds/calico-node --timeout=120s || true
kubectl -n kube-system set env ds/calico-node IP_AUTODETECTION_METHOD="interface=${IFACE}"
kubectl -n kube-system rollout status ds/calico-node --timeout=180s

# 기본 IP 풀이 실제로 POD_CIDR 로 생성되었는지 검증 (sed 치환 실패 대비)
POOL_CIDR=$(kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.cidr}' 2>/dev/null || true)
if [ -n "$POOL_CIDR" ] && [ "$POOL_CIDR" != "$POD_CIDR" ]; then
  echo "[경고] Calico 기본 IP 풀이 ${POOL_CIDR} 입니다 (기대값: ${POD_CIDR})."
  echo "       calico.yaml 형식 변경으로 sed 치환이 실패했을 수 있습니다. 수동 확인이 필요합니다."
fi

# 정상 완료되었으므로 트랩 해제
trap - ERR

echo ""
echo "=== 5. Helm CLI 도구 설치 ==="
if ! command -v helm &> /dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo ">>> Helm 설치 완료: $(helm version --short)"
else
  echo ">>> Helm이 이미 설치되어 있습니다: $(helm version --short)"
fi

echo ""
echo "=================================================================="
echo " [Master 노드 초기 설정 완료 (Kubernetes + Calico + Helm)]"
echo ""
echo " 워커 노드에서 실행할 명령어:"
echo " sudo $(kubeadm token create --print-join-command)"
echo "=================================================================="