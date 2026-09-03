#!/usr/bin/env bash
set -e

ROLE_ARG="$1"
IFACE="enp0s8"
NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
BACKUP_FILE="${NETPLAN_FILE}.bak"

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

if [ "$ROLE_ARG" -eq 1 ]; then
  STATIC_IP="192.168.56.10"
  echo "=== Master 노드 네트워크 확인 (목표 IP: ${STATIC_IP}) ==="
else
  STATIC_IP="192.168.56.20"
  echo "=== Worker 노드 네트워크 확인 (목표 IP: ${STATIC_IP}) ==="
fi

# 1. 이미 해당 IP가 인터페이스에 세팅되어 있는지 확인
CURRENT_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || true)
if [ "$CURRENT_IP" = "$STATIC_IP" ]; then
  echo "[PASS] ${IFACE}에 이미 ${STATIC_IP}가 설정되어 있습니다. 네트워크 설정을 건너뜁니다."
  exit 0
fi

# 2. 롤백 핸들러 (적용 실패 시 백업 복원)
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

# 백업 생성
[ -f "$NETPLAN_FILE" ] && sudo cp "$NETPLAN_FILE" "$BACKUP_FILE"

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
