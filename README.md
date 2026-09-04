# setup-k8s-vm

## 개요

**로컬 PC의 가상머신(VirtualBox) 위에** kubeadm 기반 Kubernetes 클러스터를 처음부터 끝까지 자동으로 구축하는 스크립트 모음입니다. 클라우드(EKS/GKE 등)가 아닌 **완전 로컬 환경**을 대상으로 하며, 학습·개발·부하 테스트용 클러스터를 반복적으로 재현하는 것이 목적입니다.

VM 2대(Master 1 + Worker 1)를 준비한 뒤 각 노드에서 `run.sh` 를 실행하면:

1. **노드 부트스트랩** — Netplan 고정 IP, swap 비활성화, 커널 모듈/sysctl, containerd, `kubeadm`/`kubelet`/`kubectl` (v1.34) 설치
2. **컨트롤 플레인 구성** (마스터) — `kubeadm init`, Calico CNI 배포, Helm 설치
3. **애드온 설치** (워커 조인 후, 마스터에서) — 아래 스택을 Helm 으로 일괄 배포

| 구분 | 구성요소 | 노출 |
|------|----------|------|
| 네트워크 | Calico CNI (`v3.32`, k8s 1.34 호환) | - |
| 인그레스 | ingress-nginx (워커 노드 `hostNetwork` 80/443) | - |
| 리소스 메트릭 | metrics-server (`kubectl top`, HPA) | - |
| 배포 | Argo CD | `argocd.<워커IP>.nip.io` |
| 모니터링 | kube-prometheus-stack (Prometheus + Grafana + node-exporter + kube-state-metrics) | `grafana.<워커IP>.nip.io`, `prometheus.<워커IP>.nip.io` |

**특징**

- 모든 스크립트는 **멱등** — 재실행 시 이미 완료된 단계는 건너뜀
- 외부 도메인/DNS 설정 없이 **nip.io 와일드카드 DNS** 로 서비스 접근 (`<name>.<IP>.nip.io` → 해당 IP)
- Helm 차트 버전은 모두 **핀 고정** (재현성)
- 모니터링에 부하 테스트용 커스텀 Grafana 대시보드 포함 (파드 스케일링·HPA·노드 여력 관측)
- 실패 시 자동 롤백 (네트워크 설정, `kubeadm init`)

## VM 환경

| 항목 | 값 |
|------|-----|
| OS | Ubuntu 24.04.4 LTS |
| 네트워크 | NAT (`enp0s3`, DHCP) + Host-Only (`enp0s8`, `192.168.56.0/24` 고정 IP) |
| 노드 IP | Master `192.168.56.10` / Worker `192.168.56.20` (기본값, `setup-network.sh` 에서 입력·변경 가능) |
| CNI Pod CIDR | `10.244.0.0/16` (노드 대역과 분리) |
| 권장 스펙 | Master 2 vCPU / 2GB, Worker 2 vCPU / 6GB (모니터링·ArgoCD·Ingress 가 워커에 집중) |

> 인터페이스 이름(`enp0s3` / `enp0s8`)은 스크립트에 하드코딩되어 있음 — VirtualBox 기본값 기준.
> NAT 어댑터는 아웃바운드(패키지 다운로드), Host-Only 어댑터는 노드 간 통신 및 서비스 접근용.

**호스트(로컬 PC) 요건**

- VirtualBox + Host-Only 네트워크 `192.168.56.0/24` (VirtualBox 기본 대역)
- 호스트에서 `192.168.56.0/24` 로 접근 가능해야 브라우저로 서비스 접속 가능 (Host-Only 라 기본 가능)
- VM 이 인터넷에 나갈 수 있어야 함 (패키지·Helm 차트·컨테이너 이미지 다운로드, `*.nip.io` 해석)
- 폐쇄망이면 `*.nip.io` 대신 호스트 `hosts` 파일에 `192.168.56.20 grafana.192.168.56.20.nip.io` 식으로 수동 등록

## 디렉터리 구조

```
run.sh                              # 진입점: 노드 역할 선택 → bootstrap → (마스터면) master
script/
  bootstrap/                        # 모든 노드 공통
    setup-network.sh                #   Netplan 고정 IP (enp0s8)
    setup-k8s-common.sh             #   swap off, containerd, kubeadm/kubelet/kubectl
  master/
    setup-k8s-master.sh             #   kubeadm init + Calico CNI + Helm
  addons/                           # 워커 조인 후 마스터에서
    install-addons.sh               #   아래 4개를 순서대로 (설치된 건 skip)
    setup-metrics-server.sh
    setup-ingress-nginx.sh          #   nginx IngressClass (워커 hostNetwork 80/443)
    setup-argocd.sh                 #   Ingress + nip.io
    setup-monitoring.sh             #   kube-prometheus-stack + 대시보드
    dashboards/
      kubernetes/                   #   dotdc Kubernetes Views 4종
      application/                  #   app-overview, load-test-overview
```

## 사용법

### 1. 각 노드에서 (마스터 먼저, 그다음 워커)
```bash
./run.sh
# 1) Master / 2) Worker 선택
```

### 2. 워커 노드 조인 (마스터 출력의 join 명령 사용)
```bash
sudo kubeadm join <MASTER_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

### 3. 애드온 설치 (마스터에서, 워커 조인 후)
```bash
./script/addons/install-addons.sh
```

## 접속 (기본, 워커 IP = 192.168.56.20 가정)

| 서비스 | URL |
|--------|-----|
| ArgoCD | http://argocd.192.168.56.20.nip.io |
| Grafana | http://grafana.192.168.56.20.nip.io |
| Prometheus | http://prometheus.192.168.56.20.nip.io |

비밀번호:
```bash
# ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# Grafana
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```
