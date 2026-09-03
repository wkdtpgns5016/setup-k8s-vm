#!/usr/bin/env bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${BASE_DIR}/script"

if [ ! -d "$SCRIPT_DIR" ]; then
  echo "에러: '${SCRIPT_DIR}' 디렉터리가 존재하지 않습니다."
  exit 1
fi

chmod +x "${SCRIPT_DIR}"/*.sh

echo "=== 노드 역할 선택 ==="
echo "1) Master"
echo "2) Worker"

while true; do
  read -rp "번호를 선택하세요 (1 또는 2): " NODE_ROLE
  case "$NODE_ROLE" in
    1|2) break ;;
    *) echo "잘못된 입력입니다. 1 또는 2를 입력하세요." ;;
  esac
done

# 1. 네트워크 스크립트에 역할 번호($NODE_ROLE)를 인자로 전달하여 실행
"${SCRIPT_DIR}/setup-network.sh" "$NODE_ROLE"

# 2. 공통 환경(k8s 패키지, 방화벽, containerd) 설정 실행
"${SCRIPT_DIR}/setup-k8s-common.sh"

# 3. 마스터 선택 시 즉시 클러스터 초기화까지 진행
if [ "$NODE_ROLE" -eq 1 ]; then
  echo ""
  echo "=== Master 노드 초기화 및 Calico 배포를 즉시 진행합니다 ==="
  "${SCRIPT_DIR}/setup-master.sh"
else
  echo ""
  echo "=================================================================="
  echo " [Worker 노드 기본 세팅 완료]"
  echo " Master에서 생성된 'sudo kubeadm join ...' 명령어를 실행하세요."
  echo "=================================================================="
fi
