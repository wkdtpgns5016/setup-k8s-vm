#!/usr/bin/env bash
set -e

# Tailscale 재인증(로그아웃/재로그인) 등으로 노드의 Tailscale IP 가 바뀐 경우,
# 이미 설치된 애드온의 ingress host 만 새 IP 기준 nip.io 주소로 즉시 패치한다.
# (재설치 없이 kubectl patch 로 host 필드만 교체 — Helm 릴리스 자체는 건드리지 않음)
#
# 대상: argocd-server(ns argocd), kube-prometheus-stack-grafana / -prometheus(ns monitoring)
#       — 설치되지 않은 애드온은 자동으로 건너뜀.
#
# 주의: helm upgrade 로 해당 애드온을 다시 설치/갱신하면(예: setup-argocd.sh 재실행),
#       그때 입력하는 Tailscale IP 로 host 가 다시 계산되어 이 패치 내용을 덮어쓸 수 있음.
#
# 사용법:
#   ./patch-tailscale-ip.sh                 # 대화형으로 새 Tailscale IP 입력
#   ./patch-tailscale-ip.sh 100.x.x.x        # 인자로 바로 전달 (비대화형)

NEW_IP="${1:-}"

if ! kubectl cluster-info &> /dev/null; then
  echo "에러: kubectl 로 클러스터에 접근할 수 없습니다. (~/.kube/config 확인)"
  exit 1
fi

if [ -z "$NEW_IP" ]; then
  read -rp "Ingress 를 붙인 노드의 새 Tailscale IP 입력: " NEW_IP
fi

if [ -z "$NEW_IP" ]; then
  echo "에러: IP 가 입력되지 않았습니다."
  exit 1
fi

if ! [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "에러: 올바른 IPv4 형식이 아닙니다: ${NEW_IP}"
  exit 1
fi

echo ">>> 새 Ingress IP: ${NEW_IP}"
echo ""

PATCHED=0

# ingress 이름  namespace  host prefix (<prefix>.<IP>.nip.io)
patch_ingress_host() {
  local ingress="$1" namespace="$2" prefix="$3" new_host cur_host
  new_host="${prefix}.${NEW_IP}.nip.io"

  if ! kubectl get ingress "$ingress" -n "$namespace" &> /dev/null; then
    echo "[SKIP] ingress '${ingress}' (ns: ${namespace}) 없음 — 미설치로 간주."
    return 0
  fi

  cur_host=$(kubectl get ingress "$ingress" -n "$namespace" -o jsonpath='{.spec.rules[0].host}')
  if [ "$cur_host" = "$new_host" ]; then
    echo "[SKIP] ${ingress}: 이미 ${new_host} 로 설정되어 있음."
    return 0
  fi

  kubectl patch ingress "$ingress" -n "$namespace" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"${new_host}\"}]" > /dev/null
  echo "[패치] ${ingress} (ns: ${namespace}): ${cur_host} -> ${new_host}"
  PATCHED=$((PATCHED + 1))
}

patch_ingress_host argocd-server                   argocd     argocd
patch_ingress_host kube-prometheus-stack-grafana    monitoring grafana
patch_ingress_host kube-prometheus-stack-prometheus monitoring prometheus

echo ""
echo "=================================================================="
if [ "$PATCHED" -eq 0 ]; then
  echo " [변경 없음] 패치할 ingress 가 없거나 이미 최신 상태입니다."
else
  echo " [패치 완료] ${PATCHED}개 ingress 갱신됨. 현재 접속 주소:"
fi
for ns_ingress in "argocd/argocd-server" "monitoring/kube-prometheus-stack-grafana" "monitoring/kube-prometheus-stack-prometheus"; do
  ns="${ns_ingress%%/*}"
  name="${ns_ingress##*/}"
  host=$(kubectl get ingress "$name" -n "$ns" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
  [ -n "$host" ] && echo "  ${ns}/${name} : http://${host}"
done
echo "=================================================================="
