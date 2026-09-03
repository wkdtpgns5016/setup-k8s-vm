#!/usr/bin/env bash
set -e

K8S_VERSION="v1.30"

echo "=== 1. Swap 비활성화 및 영구 적용 ==="
sudo swapoff -a
sudo sed -i.bak -r 's/(.+swap.+)/#\1/' /etc/fstab

echo "=== 2. 방화벽(UFW) 최소 권한 원칙 적용 ==="
# SSH 연결 유지 (NAT 포트포워딩 접속 끊김 방지)
sudo ufw allow 22/tcp

# Host-Only 내부 네트워크 인터페이스(enp0s8) 전면 허용 (노드 간 k8s 및 파드 통신)
sudo ufw allow in on enp0s8
sudo ufw allow out on enp0s8

# 파드 간 트래픽 라우팅을 위한 포워딩 정책 수락(ACCEPT) 변경
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# UFW 활성화 및 재로드
sudo ufw --force enable
sudo ufw reload

echo "=== 3. 커널 모듈 로드 및 sysctl 설정 ==="
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

echo "=== 4. 기본 의존성 패키지 설치 ==="
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release apt-transport-https

echo "=== 5. Docker GPG 키 및 containerd 설치 ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y containerd.io

echo "=== 6. containerd cgroup(SystemdCgroup) 설정 ==="
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== 7. Kubernetes 공식 저장소 등록 (버전: ${K8S_VERSION}) ==="
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "=== 8. kubelet, kubeadm, kubectl 설치 및 버전 고정 ==="
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

echo "=== 공통 환경 설정 완료 ==="
sudo ufw status verbose
