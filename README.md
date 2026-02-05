# Kubernetes_Installer_with_CRIO
현재 사용하는 tool 및 version들은 다음과 같습니다.
- Kubernetes:v1.33
- CRI:CRI-O(v1.33)
- CNI: Cillium

다음 스크립트 파일은 Root 계정으로 실행해야 합니다.
```
sudo su -
``` 
또한 현재 CRI-O 및 Kubernetes 사용 Version은 1.33으로 이를 바꾸기 위해서는 스크립트 파일에 들어가 다음을 원하는 버전으로 바꿔야 합니다.
```
KUBERNETES_VERSION="v1.33"
CRIO_VERSION="v1.33"
```

## 사용 방법
파일 다운
```
git clone https://github.com/GProjectdev/Kubernetes_Installer_with_CRIO.git
```

권한부여
```
chmod +x Kubernetes_Installer_with_CRIO/k8s-setup.sh
```

파일 실행
```
sudo ./Kubernetes_Installer_with_CRIO/k8s-setup.sh
```

## Master Node 설정이기에 해당 Node에 Pod를 배포하기 위해서는 다음을 진행해야 합니다.
```
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## 🗑️ Kubernetes 안전 제거 (Clean Uninstallation)

설치된 Kubernetes 환경을 안전하게 제거하고 초기화해야 할 경우, `k8s_clean_uninstall.sh` 스크립트를 사용하세요.
이 스크립트는 **"Ultra-Safe Mode"**로 설계되어, 실수로 중요한 데이터나 네트워크 설정이 삭제되지 않도록 보호합니다.

### 🚀 빠른 사용법 (기본 안전 모드)
가장 권장되는 방식입니다. Kubernetes 관련 서비스와 바이너리만 깔끔하게 제거하며, 중요 데이터와 네트워크 설정은 보존합니다.

1. **실행 권한 부여**
   ```bash
   chmod +x k8s_clean_uninstall.sh
   ```

2. **스크립트 실행**
   ```bash
   sudo ./k8s_clean_uninstall.sh
   ```
   > **Note:** 실행 후 완벽한 정리를 위해 서버 재부팅(`sudo reboot`)을 권장합니다.

---

### ⚙️ 고급 옵션 (완전 초기화)
개발 환경 초기화 등을 위해 모든 데이터를 지워야 한다면, 아래 옵션들을 **직접 추가(Opt-in)** 해야 합니다. 사용자는 필요한 만큼 옵션을 조합하여 사용할 수 있습니다.

| 옵션 | 설명 | 주의사항 |
| :--- | :--- | :--- |
| **`--cleanup-cni`** | CNI 네트워크 인터페이스(`cni0` 등) 및 설정 삭제 | 해당 노드가 K8s 전용일 때만 사용 권장 |
| **`--cleanup-etcd`** | Etcd 데이터(`/var/lib/etcd`) 삭제 | **데이터 복구 불가**. 백업 필요 시 주의 |
| **`--autoremove`** | 사용하지 않는 의존성 패키지 자동 정리 | 다른 프로그램과 의존성이 있는지 확인 필요 |

**완전 삭제 예시 명령어:**
```bash
# 네트워크, 데이터, 잔여 패키지까지 모두 싹 지우기 (주의!)
sudo ./k8s_clean_uninstall.sh --cleanup-cni --cleanup-etcd --autoremove
```

---

### 🛡️ 왜 이 스크립트가 안전한가요?
1. **파괴 작업 방지:** 네트워크 삭제, 데이터 삭제 등 위험한 작업은 기본적으로 **비활성화**되어 있습니다.
2. **K8s 흔적 감지:** `--cleanup-cni` 옵션을 켜더라도, 실제로 Kubernetes가 설치되었던 흔적(설정 파일 등)이 없으면 네트워크 삭제를 **자동으로 차단**합니다.
3. **정밀 타격:** 무분별한 와일드카드(`rm -rf /usr/bin/kube*`) 대신, 정확한 파일 경로와 패키지 이름만 확인하여 삭제합니다.
