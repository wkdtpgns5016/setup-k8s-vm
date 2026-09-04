#!/usr/bin/env bash
set -e

ROLE_ARG="$1"
IFACE="enp0s8"
NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
BACKUP_FILE="${NETPLAN_FILE}.bak"

# 1. 역할 선택 (인자로 넘어오지 않은 경우에만 질문)
if [ -z "$ROLE_ARG" ]; then
  echo "=== 노드 역할 선택 ==="
  echo "1) Master"
  echo "2) Worker"
  while true; do
    read -rp "번호를 선택하세요 (1 또는 2): " ROLE_ARG
    case "$ROLE_ARG" in
      1|2) break ;;
      *) echo "잘못된 입력입니다. 1 또는 2를 입력하세요." ;;
    esac
  done
fi

ROLE_NAME="Worker"
HOST_NUM="20"
if [ "$ROLE_ARG" -eq 1 ]; then
  ROLE_NAME="Master"
  HOST_NUM="10"
fi

# 2. 서브넷 대역 감지 시도 (기존 할당 IP 또는 이전 Netplan 파일)
DETECTED_PREFIX=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+' | head -n 1 || true)

if [ -z "$DETECTED_PREFIX" ]; then
  DETECTED_PREFIX=$(grep -oP '\d+\.\d+\.\d+(?=\.\d+/\d+)' /etc/netplan/*.yaml 2>/dev/null | head -n 1 || true)
fi

# 3. 대역 감지 여부에 따른 사용자 IP 입력 처리
echo ""
if [ -n "$DETECTED_PREFIX" ]; then
  DEFAULT_IP="${DETECTED_PREFIX}.${HOST_NUM}"
  echo "감지된 서브넷 대역: ${DETECTED_PREFIX}.0/24"
  read -rp "${ROLE_NAME} IP 입력 [기본값: ${DEFAULT_IP}]: " USER_IP
  STATIC_IP="${USER_IP:-$DEFAULT_IP}"
else
  DEFAULT_IP="192.168.56.${HOST_NUM}"
  echo "알림: 기존 IP 및 DHCP 정보가 없어 네트워크 대역을 자동 감지할 수 없습니다."
  echo "VirtualBox '호스트 네트워크 관리자'의 어댑터 대역(기본 대역: 192.168.56.0/24)을 기준으로 제안합니다."
  read -rp "${ROLE_NAME} IP 입력 [기본값: ${DEFAULT_IP}]: " USER_IP
  STATIC_IP="${USER_IP:-$DEFAULT_IP}"
fi

echo "=== ${ROLE_NAME} 노드 네트워크 설정 (목표 IP: ${STATIC_IP}) ==="

# 4. 멱등성 검사 (이미 목표 IP가 할당되어 있다면 작업 스킵)
CURRENT_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || true)
if [ "$CURRENT_IP" = "$STATIC_IP" ]; then
  echo "[PASS] ${IFACE}에 이미 ${STATIC_IP}가 설정되어 있습니다. 네트워크 설정을 건너뜁니다."
  exit 0
fi

# 5. 실패 시 롤백 핸들러
rollback_network() {
  local code=$?
  if [ -f "$BACKUP_FILE" ]; then
    echo "[Rollback] 네트워크 적용 실패. 이전 Netplan 설정을 복원합니다."
    sudo cp -f "$BACKUP_FILE" "$NETPLAN_FILE"
    sudo netplan apply || true
  fi
  exit "$code"
}
trap rollback_network ERR

# 기존 파일 백업
[ -f "$NETPLAN_FILE" ] && sudo cp "$NETPLAN_FILE" "$BACKUP_FILE"

# 6. Netplan 설정 작성 (NAT enp0s3: DHCP / Host-Only enp0s8: 고정 IP)
cat <<EOF | sudo tee "$NETPLAN_FILE" > /dev/null
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/24
EOF

sudo chmod 600 "$NETPLAN_FILE"
sudo netplan apply

# 7. 인터페이스 IP 바인딩 완료 대기 루프
echo "${IFACE} IP 바인딩 대기 중..."
TIMEOUT=10
COUNT=0
until ip -4 addr show "$IFACE" | grep -q "${STATIC_IP}"; do
  sleep 1
  COUNT=$((COUNT + 1))
  if [ "$COUNT" -ge "$TIMEOUT" ]; then
    echo "에러: ${TIMEOUT}초 내에 ${STATIC_IP} 바인딩 실패."
    false
  fi
done

trap - ERR
echo "네트워크 설정 완료: $(ip -4 addr show "$IFACE" | grep inet)"
