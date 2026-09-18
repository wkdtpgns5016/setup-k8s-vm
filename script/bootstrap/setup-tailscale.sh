#!/usr/bin/env bash
set -e

# [선택 / 수동 실행] 이 VM 을 Tailscale 에 연결한다.
#   Master: Host-Only 대역(192.168.56.0/24 = 클러스터 API·Ingress·노드)을 광고하는 서브넷 라우터로 구성.
#   Worker: 서브넷 라우팅 없이 자체 Tailscale IP 만 획득
#           (ingress-nginx 가 hostNetwork 로 워커에 떠 있다면, 이 IP 로 80/443 에 바로 접근 가능).
# run.sh 로 자동 실행되지 않음 — 클러스터 구축 완료 후 필요할 때 해당 노드에서 직접 실행.
#
# 사용법:
#   ./setup-tailscale.sh                  # 대화형 로그인 (URL 출력 → 브라우저에서 계정 로그인)
#   ./setup-tailscale.sh tskey-auth-xxxx  # 사전 발급 auth key 로 비대화형
#   TS_AUTHKEY=tskey-auth-xxxx ./setup-tailscale.sh

IFACE="enp0s8"
AUTHKEY="${1:-${TS_AUTHKEY:-}}"

echo "=== 노드 역할 선택 ==="
echo "1) Master (Host-Only 대역 서브넷 라우터로 구성)"
echo "2) Worker (자체 Tailscale IP 만 획득, 서브넷 라우팅 없음)"
while true; do
  read -rp "번호를 선택하세요 (1 또는 2): " NODE_ROLE
  case "$NODE_ROLE" in
    1|2) break ;;
    *) echo "잘못된 입력입니다. 1 또는 2를 입력하세요." ;;
  esac
done

if [ "$NODE_ROLE" -eq 1 ]; then
  HOSTNAME_TS="k8s-master"
else
  HOSTNAME_TS="k8s-worker"
fi

echo "=== Tailscale 설정 (${HOSTNAME_TS}) ==="

NODE_IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

if [ "$NODE_ROLE" -eq 1 ]; then
  # 1. Host-Only 대역 자동 감지 → 광고할 route 결정 (기본 192.168.56.0/24)
  if [ -n "$NODE_IP" ]; then
    ADVERTISE_ROUTE="${NODE_IP%.*}.0/24"
  else
    ADVERTISE_ROUTE="192.168.56.0/24"
    echo "[경고] ${IFACE} IP 감지 실패 — 기본값 ${ADVERTISE_ROUTE} 사용"
  fi
  echo "광고할 서브넷: ${ADVERTISE_ROUTE}"
fi

# 2. 설치 (멱등)
if ! command -v tailscale &> /dev/null; then
  echo ">>> Tailscale 설치..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "[SKIP] Tailscale 이미 설치됨 ($(tailscale version | head -n1))"
fi

# 3. IP forwarding (서브넷 라우팅 필수) — 멱등, Master 에서만 필요
if [ "$NODE_ROLE" -eq 1 ]; then
  if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ] || \
     [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" != "1" ]; then
    echo ">>> IP forwarding 활성화..."
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
      | sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null
  fi
fi

# 4. tailscale up (Worker 는 서브넷 광고 없이 참여만 함)
#    --reset : 이전 수동 설정(예: 예전에 다른 역할로 advertise-routes 를 걸어둔 경우) 이 남아있어도
#              언급하지 않은 플래그는 기본값으로 초기화하고 아래 값만 그대로 적용
if [ "$NODE_ROLE" -eq 1 ]; then
  UP_ARGS=(--reset --advertise-routes="${ADVERTISE_ROUTE}" --accept-dns=false --hostname="${HOSTNAME_TS}")
else
  UP_ARGS=(--reset --accept-dns=false --hostname="${HOSTNAME_TS}")
fi
tailscale_up() {
  if [ -n "$AUTHKEY" ]; then
    echo ">>> tailscale up (auth key)..."
    sudo tailscale up "${UP_ARGS[@]}" --authkey="${AUTHKEY}"
  else
    echo ">>> tailscale up — 출력되는 URL 을 브라우저에서 열어 로그인하세요 (외부 기기와 같은 계정)."
    sudo tailscale up "${UP_ARGS[@]}"
  fi
}
tailscale_up

# 5. 좌표 서버 연결 확인 — Tailscale 관리 콘솔에서 이 머신을 삭제한 뒤 재실행한 경우,
#    로컬에 남은 예전 노드 키 때문에 "로그인됨"으로 오인해 위 tailscale up 이 로그인 URL 없이
#    조용히 끝나지만 실제로는 offline 상태가 되는 경우가 있음 → 감지 시 재로그인으로 복구.
if tailscale status 2>&1 | grep -q "Unable to connect to the Tailscale coordination server"; then
  echo "[경고] 좌표 서버와 통신 불가 — 로컬에 남은 인증 정보가 무효화된 것으로 보입니다 (콘솔에서 삭제됨 등)."
  echo ">>> 재로그인을 위해 로그아웃 후 다시 시도합니다..."
  sudo tailscale logout
  tailscale_up
fi

TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)

echo ""
echo "=================================================================="
echo " [Tailscale 설정 완료]"
echo "  이 노드 Tailscale IP : ${TS_IP:-'tailscale ip -4' 로 확인}"
if [ "$NODE_ROLE" -eq 1 ]; then
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
else
  echo ""
  echo "  이 워커 노드에 ingress-nginx(hostNetwork) 가 떠 있다면,"
  echo "  애드온 설치 시 위 Tailscale IP 를 입력하면 <서비스>.${TS_IP:-<Tailscale IP>}.nip.io 로 접속할 수 있습니다."
fi
echo "=================================================================="
