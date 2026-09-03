#!/usr/bin/env bash
set -e

ROLE_ARG="$1"

# 인자가 넘어오지 않은 경우에만 직접 사용자에게 질문
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

# 역할에 따른 고정 IP 자동 할당
if [ "$ROLE_ARG" -eq 1 ]; then
  STATIC_IP="192.168.56.10"
  echo "=== Master 노드 네트워크 설정 (IP: ${STATIC_IP}) ==="
else
  STATIC_IP="192.168.56.20"
  echo "=== Worker 노드 네트워크 설정 (IP: ${STATIC_IP}) ==="
fi

NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"

# 기존 설정 백업
if [ -f "$NETPLAN_FILE" ]; then
  sudo cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
fi

# Netplan 설정 작성 (NAT enp0s3: DHCP / Host-Only enp0s8: 고정 IP)
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

echo "네트워크 설정 적용 완료."
ip -4 addr show enp0s8 | grep inet
