#!/usr/bin/env bash
set -e

K8S_VERSION="v1.30"
IFACE="enp0s8"

echo "=== 1. Swap 비활성화 검사 ==="
sudo swapoff -a
if grep -qE '^[^#].*\sswap\s' /etc/fstab; then
  sudo sed -i.bak -r 's/(^.*swap.*$)/#\1/' /etc/fstab
  echo "Swap 설정 주석 처리 완료."
else
  echo "[PASS] Swap이 이미 비활성화되어 있습니다."
fi

echo "=== 2. 방화벽(UFW) 상태 및 규칙 검사 ==="
sudo ufw allow 22/tcp >/dev/null
sudo ufw allow in on "$IFACE" >/dev/null
sudo ufw allow out on "$IFACE" >/dev/null
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

if sudo ufw status | grep -q "Status: inactive"; then
  sudo ufw --force enable
fi
sudo ufw reload >/dev/null
echo "UFW 규칙 동기화 완료."

echo "=== 3. 커널 모듈 및 sysctl 검사 ==="
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

echo "=== 4. 기본 의존 패키지 확인 ==="
REQUIRED_PKGS=(ca-certificates curl gnupg lsb-release apt-transport-https)
MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  sudo apt update
  sudo apt install -y "${MISSING_PKGS[@]}"
else
  echo "[PASS] 기본 패키지가 이미 모두 설치되어 있습니다."
fi

echo "=== 5. containerd 설치 및 설정 검사 ==="
if ! dpkg -s containerd.io >/dev/null 2>&1; then
  sudo mkdir -p /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y containerd.io
fi

sudo mkdir -p /etc/containerd
# SystemdCgroup 활성화 상태 확인 및 재작성
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  sudo systemctl restart containerd
fi
sudo systemctl enable --now containerd >/dev/null

echo "=== 6. Kubernetes 패키지 검사 ==="
if ! dpkg -s kubeadm >/dev/null 2>&1; then
  sudo mkdir -p /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
  fi
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt update
  sudo apt install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl >/dev/null
fi

sudo systemctl enable --now kubelet >/dev/null
echo "공통 환경 준비 완료."
