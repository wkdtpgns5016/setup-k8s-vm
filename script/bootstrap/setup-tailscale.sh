#!/usr/bin/env bash
set -e

# [선택 / 수동 실행] 마스터 VM 을 Tailscale 서브넷 라우터로 구성한다.
# 외부 기기(맥북 등)에서 Host-Only 대역(192.168.56.0/24 = 클러스터 API·Ingress·노드)에 접근하기 위함.
# run.sh 로 자동 실행되지 않음 — 클러스터 구축 완료 후 마스터에서 필요할 때 직접 실행.
#
# 사용법:
#   ./setup-tailscale.sh                  # 대화형 로그인 (URL 출력 → 브라우저에서 계정 로그인)
#   ./setup-tailscale.sh tskey-auth-xxxx  # 사전 발급 auth key 로 비대화형
#   TS_AUTHKEY=tskey-auth-xxxx ./setup-tailscale.sh

IFACE="enp0s8"
HOSTNAME_TS="k8s-master"
AUTHKEY="${1:-${TS_AUTHKEY:-}}"

echo "=== Tailscale 서브넷 라우터 설정 ==="

# 1. Host-Only 대역 자동 감지 → 광고할 route 결정 (기본 192.168.56.0/24)
NODE_IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
if [ -n "$NODE_IP" ]; then
  ADVERTISE_ROUTE="${NODE_IP%.*}.0/24"
else
  ADVERTISE_ROUTE="192.168.56.0/24"
  echo "[경고] ${IFACE} IP 감지 실패 — 기본값 ${ADVERTISE_ROUTE} 사용"
fi
echo "광고할 서브넷: ${ADVERTISE_ROUTE}"

# 2. 설치 (멱등)
if ! command -v tailscale &> /dev/null; then
  echo ">>> Tailscale 설치..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "[SKIP] Tailscale 이미 설치됨 ($(tailscale version | head -n1))"
fi

# 3. IP forwarding (서브넷 라우팅 필수) — 멱등
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ] || \
   [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" != "1" ]; then
  echo ">>> IP forwarding 활성화..."
  printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
    | sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null
  sudo sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null
fi

# 4. tailscale up
UP_ARGS=(--advertise-routes="${ADVERTISE_ROUTE}" --accept-dns=false --hostname="${HOSTNAME_TS}")
if [ -n "$AUTHKEY" ]; then
  echo ">>> tailscale up (auth key)..."
  sudo tailscale up "${UP_ARGS[@]}" --authkey="${AUTHKEY}"
else
  echo ">>> tailscale up — 출력되는 URL 을 브라우저에서 열어 로그인하세요 (외부 기기와 같은 계정)."
  sudo tailscale up "${UP_ARGS[@]}"
fi

TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)

echo ""
echo "=================================================================="
echo " [Tailscale 설정 완료]"
echo "  이 노드 Tailscale IP : ${TS_IP:-'tailscale ip -4' 로 확인}"
echo "  광고 서브넷           : ${ADVERTISE_ROUTE}"
echo ""
echo "  ⚠️  마지막 단계 (Tailscale 관리 콘솔에서 수동 승인):"
echo "    https://login.tailscale.com/admin/machines"
echo "    → '${HOSTNAME_TS}' → Subnet routes → ${ADVERTISE_ROUTE} 'Approve'"
echo ""
echo "  외부 맥북에서:"
echo "    brew install --cask tailscale && tailscale up      # 같은 계정으로 로그인"
echo "    sudo tailscale set --accept-routes"
echo "    scp <user>@${NODE_IP:-192.168.56.10}:~/.kube/config ~/.kube/config"
echo "    kubectl get nodes"
echo "=================================================================="
