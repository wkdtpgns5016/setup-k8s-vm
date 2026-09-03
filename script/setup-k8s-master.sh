#!/usr/bin/env bash
set -e

IFACE="enp0s8"
POD_CIDR="192.168.0.0/16"
CALICO_VERSION="v3.28.0"

echo "=== 1. Host-Only IP 자동 감지 ==="
MASTER_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

if [ -z "$MASTER_IP" ]; then
  echo "에러: ${IFACE} 인터페이스에서 IP 주소를 찾을 수 없습니다."
  echo "먼저 setup-network.sh 실행 여부를 확인하세요."
  exit 1
fi

echo "감지된 Master IP: ${MASTER_IP} (${IFACE})"

echo ""
echo "=== 2. kubeadm 초기화 시작 ==="
sudo kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}"

echo ""
echo "=== 3. kubectl 권한 설정 (사용자: ${USER}) ==="
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo ""
echo "=== 4. Calico CNI (${CALICO_VERSION}) 배포 ==="
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo ""
echo "=== 5. 워커 노드 조인(Join) 명령어 생성 ==="
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "$JOIN_CMD" > "$HOME/join-command.txt"

echo "=================================================================="
echo " [Master 노드 설정 완료]"
echo ""
echo " 워커 노드에서 실행할 명령어:"
echo " sudo $JOIN_CMD"
echo "=================================================================="
