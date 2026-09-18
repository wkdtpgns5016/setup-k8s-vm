#!/usr/bin/env bash
# 공통 라이브러리: nip.io 기반 ingress hostname 에 사용할 IP 결정
#   - 기본: 워커 노드의 Host-Only(InternalIP) 주소 (기존 동작, 하위 호환 유지)
#   - Tailscale 로 다른 네트워크(맥북 등)와 연결된 환경이라면, 사용자가 입력한
#     Tailscale IP 를 대신 사용 (ingress-nginx 가 hostNetwork 로 떠 있어 별도 설정 없이 동작)
#
# 사용법: source "${SCRIPT_DIR}/lib-ingress-ip.sh" 후 resolve_ingress_ip 호출
#         → 결과 IP 는 $RESOLVED_INGRESS_IP 에 저장됨
#
# install-addons.sh 처럼 여러 애드온 스크립트를 연달아 실행하는 경우, 매번 다시 묻지 않도록
# TAILSCALE_ANSWERED=1 / TAILSCALE_INGRESS_IP=<IP 또는 빈 문자열> 을 미리 export 해두면
# 이 함수는 프롬프트 없이 그 값을 그대로 사용한다.

resolve_ingress_ip() {
  local worker_ip
  worker_ip=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')

  if [ -z "$worker_ip" ]; then
    echo "에러: 워커 노드를 찾을 수 없습니다." >&2
    return 1
  fi

  if [ -z "${TAILSCALE_ANSWERED:-}" ]; then
    local use_tailscale
    read -rp "Tailscale 로 다른 네트워크(맥북 등)와 연결된 환경입니까? Ingress 주소를 Tailscale IP 기준으로 설정할까요? (y/N): " use_tailscale
    case "$use_tailscale" in
      y|Y|yes|YES)
        read -rp "Ingress 를 붙일 노드(보통 워커)의 Tailscale IP 입력: " TAILSCALE_INGRESS_IP
        ;;
      *)
        TAILSCALE_INGRESS_IP=""
        ;;
    esac
    TAILSCALE_ANSWERED=1
  fi

  if [ -n "${TAILSCALE_INGRESS_IP:-}" ]; then
    RESOLVED_INGRESS_IP="$TAILSCALE_INGRESS_IP"
  else
    RESOLVED_INGRESS_IP="$worker_ip"
  fi
}
