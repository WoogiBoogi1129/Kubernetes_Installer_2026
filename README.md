# Kubernetes Installer (Kubeadm + CRI-O + Cilium)

Ubuntu/Debian 환경에서 **단 한 번의 스크립트 실행**으로 프로덕션 수준의 Kubernetes 환경을 구축할 수 있습니다.
최신 버전의 **Kubernetes (v1.35+)**, **CRI-O**, **Cilium**을 자동으로 설치 및 구성하며, 운영 환경에 필수적인 커널 설정과 보안 조치가 포함되어 있습니다.

---

## 🛠️ 주요 기능

- **자동화된 설치**: 필수 의존성 설치 → 시스템 설정 영구화(Swap off, Sysctl, Modules) → Repo 등록 → 패키지 설치 → 클러스터 초기화 → Helm & Cilium 설치
- **안정성 강화**:
  - `set -e`, `pipefail` 적용으로 에러 발생 시 즉시 중단
  - **Kernel Version Check**: Cilium 1.18+ 호환성을 위한 엄격한 커널 버전 체크 (5.10+ 필수)
  - **입력 검증**: 정규식을 통한 버전 포맷 검증 및 안정성 체크
- **네트워크 정합성**: kubeadm `--pod-network-cidr`와 Cilium IPAM 모드(`kubernetes`) 자동 동기화
- **사용자 편의**:
  - `sudo` 사용자 및 `root` 사용자 모두에게 kubeconfig 자동 복사
  - kubectl 자동 완성 및 alias(`k`) 등록

---

## 📋 전제 조건 (Prerequisites)

- **OS**: Ubuntu 22.04 LTS / 24.04 LTS (권장) 또는 Debian 계열
- **Kernel**: **Linux Kernel 5.10 이상** (Cilium 1.18.x 필수 요구사항)
- **Privilege**: Root 권한 (`sudo -i` 또는 `sudo` 실행)
- **Network**: 외부 인터넷 접속 필요

---

## 🚀 사용 가이드 (Quick Start)

### 1. 스크립트 다운로드 및 권한 부여
```bash
git clone https://github.com/WoogiBoogi1129/Kubernetes_Installer_2026.git
cd Kubernetes_Installer_2026
chmod +x k8s-setup.sh
```

### 2. 설치 실행
반드시 **Root** 권한이 필요합니다.
```bash
# 권장: sudo 사용
sudo ./k8s-setup.sh

# 또는 root 쉘에서 실행
sudo -i
./k8s-setup.sh
```

### 3. 설치 과정 상호작용
스크립트를 실행하면 설치할 버전을 묻습니다.
```text
============================================================
 Kubernetes Installation Setup
============================================================
Enter Kubernetes Version to install (e.g., v1.35) [Default: v1.35]: 
```
- **Enter 입력 시**: 기본값(최신 v1.35)으로 설치가 진행됩니다.
- **버전 지정 시**: `v1.34`와 같이 입력하면 해당 버전의 Kubernetes 및 호환되는 CRI-O가 설치됩니다.
- **검증**: 시스템은 자동으로 커널 버전과 입력 형식을 검증하고 설치를 진행합니다.

### 4. 설치 확인
설치가 완료되면 쉘을 재로딩하여 설정을 적용하세요.
```bash
source ~/.bashrc

# 노드 상태 확인 (Ready 상태여야 함)
k get nodes

# 모든 팟 상태 확인 (Cilium 포함 Running 상태여야 함)
k get pods -A
```

---

## 🧪 테스트 환경 (Single Node)
이 스크립트는 Single Control Plane 구성을 기본으로 합니다.
만약 **단일 노드**에서 파드를 배포하고 싶다면(Control Plane 노드에 스케줄링 허용), 아래 명령어를 추가로 실행하세요:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

---

## 🗑️ 제거 및 초기화 (Clean Uninstall)

설치된 Kubernetes 환경을 안전하게 제거하고 초기화해야 할 경우, `k8s_clean_uninstall.sh`를 사용하세요.

```bash
chmod +x k8s_clean_uninstall.sh
sudo ./k8s_clean_uninstall.sh
```
> 상세한 제거 옵션은 스크립트 내부 도움말이나 하단 내용을 참고하세요.

### 제거 스크립트 옵션
| 옵션 | 설명 | 주의사항 |
| :--- | :--- | :--- |
| **`--cleanup-cni`** | CNI 인터페이스(`cni0` 등) 삭제 | K8s 전용 노드일 때만 권장 |
| **`--cleanup-etcd`** | Etcd 데이터(`/var/lib/etcd`) 삭제 | **데이터 복구 불가** |
| **`--autoremove`** | 의존성 패키지 자동 정리 | 타 프로그램 영향 확인 필요 |

---

## 📦 기술 스택 버전 정보
기본 설치 시 적용되는 버전은 다음과 같습니다. (스크립트 실행 시 변경 가능)

| Component | Default Version | Note |
| :--- | :--- | :--- |
| **Kubernetes** | `v1.35` | 입력값에 따라 변경됨 |
| **CRI-O** | `v1.35` | Kubernetes 버전과 자동 동기화 |
| **Cilium** | `1.18.6` | 최신 안정 버전 (Kernel 5.10+ Required) |
| **Helm** | Latest | 공식 인스톨러 사용 |
