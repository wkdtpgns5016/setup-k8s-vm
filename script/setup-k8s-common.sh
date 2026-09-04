#!/usr/bin/env bash
set -e

echo "=== [1/5] 스왑(Swap) 비활성화 ==="
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "=== [2/5] 커널 모듈 및 네트워크 커널 파라미터 설정 ==="
cat <<MODULES | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MODULES

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<SYSCTL | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sudo sysctl --system > /dev/null

echo "=== [3/5] 필수 패키지 및 containerd 설치 ==="
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== [4/5] 쿠버네티스 패키지 저장소 등록 및 설치 ==="
K8S_VERSION="v1.31"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "=== [5/5] Host-Only (enp0s8 / en0s8) Kubelet Node IP 설정 ==="
# en0s8 또는 enp0s8 인터페이스에서 IPv4 주소 직접 추출
TARGET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en0s8|enp0s8)$' | head -n 1)

if [ -n "$TARGET_IFACE" ]; then
  CURRENT_NODE_IP=$(ip -4 addr show dev "$TARGET_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
fi

if [ -z "$CURRENT_NODE_IP" ]; then
  echo "[경고] en0s8 / enp0s8 인터페이스의 IP를 찾을 수 없습니다. 수동 확인이 필요합니다."
else
  echo "탐지된 인터페이스: ${TARGET_IFACE} (IP: ${CURRENT_NODE_IP})"
  echo "KUBELET_EXTRA_ARGS=\"--node-ip=${CURRENT_NODE_IP}\"" | sudo tee /etc/default/kubelet
  sudo systemctl daemon-reload
  sudo systemctl restart kubelet
  echo "Kubelet --node-ip 설정 완료 (${CURRENT_NODE_IP})"
fi

echo "=========================================================="
echo ">>> 기본 환경 설정 완료!"
echo "=========================================================="
