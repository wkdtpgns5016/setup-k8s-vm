#!/usr/bin/env bash
set -e

IFACE="enp0s8"
POD_CIDR="192.168.0.0/16"
CALICO_VERSION="v3.28.0"

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
  
  # 토큰만 재생성해서 출력
  JOIN_CMD=$(sudo kubeadm token create --print-join-command 2>/dev/null || true)
  if [ -n "$JOIN_CMD" ]; then
    echo "$JOIN_CMD" > "$HOME/join-command.txt"
    echo "=================================================================="
    echo " [기존 클러스터 토큰 갱신 완료]"
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
echo "=== 2. kubeadm 초기화 시작 ==="
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
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# 정상 완료되었으므로 트랩 해제
trap - ERR

echo ""
echo "=== 5. 워커 노드 조인 명령어 생성 ==="
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "$JOIN_CMD" > "$HOME/join-command.txt"

echo "=================================================================="
echo " [Master 노드 초기 설정 완료]"
echo ""
echo " 워커 노드 실행 명령어:"
echo " sudo $JOIN_CMD"
echo "=================================================================="
