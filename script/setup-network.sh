#!/usr/bin/env bash
set -e

echo "=== [1/2] 노드 역할 선택 ==="
echo "1) Master"
echo "2) Worker"

while true; do
  read -rp "번호를 선택하세요 (1 또는 2): " CHOICE
  case "$CHOICE" in
    1)
      ROLE="Master"
      DEFAULT_IP="192.168.56.10"
      break
      ;;
    2)
      ROLE="Worker"
      DEFAULT_IP="192.168.56.20"
      break
      ;;
    *)
      echo "잘못된 입력입니다. 1 또는 2를 눌러주세요."
      ;;
  esac
done

echo ""
echo "=== [2/2] IP 설정 ==="
read -rp "${ROLE} 노드에 할당할 IP를 입력하세요 [${DEFAULT_IP}]: " INPUT_IP
STATIC_IP="${INPUT_IP:-$DEFAULT_IP}"

echo ""
echo "----------------------------------------"
echo "역할: ${ROLE}"
echo "적용 IP: ${STATIC_IP}/24"
echo "----------------------------------------"
read -rp "위 설정으로 진행하시겠습니까? (Y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "설정을 취소했습니다."
  exit 0
fi

# 1. 기존 설정 백업
NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
if [ -f "$NETPLAN_FILE" ]; then
  sudo cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
fi

# 2. Netplan 파일 생성
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

# 3. 권한 부여 및 적용
sudo chmod 600 "$NETPLAN_FILE"
sudo netplan apply

echo ""
echo "=== 설정 완료 ==="
ip -4 addr show enp0s8
