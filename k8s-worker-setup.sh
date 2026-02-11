#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Kubernetes Worker Install Script (Kubeadm + CRI-O)
#
# Target OS: Ubuntu/Debian based systems
# Role: Worker node setup and cluster join
# Security: Enforces Root verification, strict error handling, dependency checks
# ==============================================================================

trap 'echo "[ERROR] Script failed at line ${LINENO} near command: ${BASH_COMMAND}" >&2' ERR

APT_GET=(apt-get -o Dpkg::Lock::Timeout=120 -o Acquire::Retries=3)

# ------------------------------------------------------------------------------
# 0. Safety & Environment Checks
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] This script must be run as root." >&2
  echo "Usage: sudo -i, then run this script." >&2
  exit 1
fi

umask 022

# Abort if node already joined a cluster
if [ -f "/etc/kubernetes/kubelet.conf" ] || [ -d "/etc/kubernetes/pki" ]; then
  echo "[ERROR] Detected existing Kubernetes node configuration." >&2
  echo "Files found: /etc/kubernetes/kubelet.conf OR /etc/kubernetes/pki" >&2
  echo "Please run 'kubeadm reset' or clean up the environment before running this script." >&2
  exit 1
fi

# Kernel Version Check (Cilium datapath compatibility on workers)
CURRENT_KERNEL_FULL=$(uname -r)
CURRENT_KERNEL_MAIN=$(echo "$CURRENT_KERNEL_FULL" | cut -d- -f1)
MIN_KERNEL="5.10"

if dpkg --compare-versions "$CURRENT_KERNEL_MAIN" lt "$MIN_KERNEL"; then
  echo "[ERROR] This setup requires Linux Kernel $MIN_KERNEL or higher." >&2
  echo "        Current Kernel: $CURRENT_KERNEL_MAIN ($CURRENT_KERNEL_FULL)" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 1. Configuration & User Input
# ------------------------------------------------------------------------------
DEFAULT_K8S_VER="v1.35"

echo "============================================================"
echo " Kubernetes Worker Installation Setup"
echo "============================================================"

echo -n "Enter Kubernetes Version to install (e.g., v1.35) [Default: ${DEFAULT_K8S_VER}]: "
read -r USER_INPUT

if [ -z "$USER_INPUT" ]; then
  KUBERNETES_VERSION="${DEFAULT_K8S_VER}"
else
  if [[ "${USER_INPUT}" != v* ]]; then
    KUBERNETES_VERSION="v${USER_INPUT}"
  else
    KUBERNETES_VERSION="${USER_INPUT}"
  fi
fi

if [[ ! "${KUBERNETES_VERSION}" =~ ^v1\.[0-9]{2}$ ]]; then
  echo "[ERROR] Invalid version format: ${KUBERNETES_VERSION}. Expected format: v1.XX (e.g., v1.35)" >&2
  exit 1
fi

CRIO_VERSION="${KUBERNETES_VERSION}"

echo -n "Enter Control Plane Endpoint (e.g., 10.0.0.10:6443): "
read -r CONTROL_PLANE_ENDPOINT
if [[ ! "${CONTROL_PLANE_ENDPOINT}" =~ ^[a-zA-Z0-9._-]+:[0-9]{2,5}$ ]]; then
  echo "[ERROR] Invalid endpoint format: ${CONTROL_PLANE_ENDPOINT}. Expected host:port" >&2
  exit 1
fi

echo -n "Enter kubeadm join token (e.g., abcdef.0123456789abcdef): "
read -r JOIN_TOKEN
if [[ ! "${JOIN_TOKEN}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; then
  echo "[ERROR] Invalid token format." >&2
  exit 1
fi

echo -n "Enter discovery token CA cert hash (e.g., sha256:...): "
read -r DISCOVERY_HASH
if [[ ! "${DISCOVERY_HASH}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "[ERROR] Invalid discovery hash format." >&2
  exit 1
fi

echo -n "Enter node name override (optional, press Enter to skip): "
read -r NODE_NAME

echo ""
echo "------------------------------------------------------------"
echo " [Configuration Confirm]"
echo " - Kubernetes Version : ${KUBERNETES_VERSION}"
echo " - CRI-O Version      : ${CRIO_VERSION}"
echo " - Control Plane      : ${CONTROL_PLANE_ENDPOINT}"
echo " - Kernel Version     : ${CURRENT_KERNEL_FULL} (OK)"
if [ -n "${NODE_NAME}" ]; then
  echo " - Node Name Override : ${NODE_NAME}"
else
  echo " - Node Name Override : (none)"
fi
echo "------------------------------------------------------------"
echo "Starting installation in 3 seconds... (Press Ctrl+C to cancel)"
sleep 3
echo ""

# ------------------------------------------------------------------------------
# 2. System Preparation
# ------------------------------------------------------------------------------
echo "[Step 1] System Configuration (Deps, Swap, Modules, Sysctl)"

export DEBIAN_FRONTEND=noninteractive

"${APT_GET[@]}" update
"${APT_GET[@]}" install -y --no-install-recommends \
    software-properties-common curl gnupg2 bash-completion \
    apt-transport-https ca-certificates \
    conntrack socat iproute2 iptables ebtables

swapoff -a
if grep -q "swap" /etc/fstab; then
    echo " > Disabling swap in /etc/fstab (Backup created at /etc/fstab.bak)..."
    sed -ri.bak '/\sswap\s/s/^/#/' /etc/fstab
fi

# Mask all systemd-managed swap units to keep swap disabled after reboot.
while read -r swap_unit; do
    [ -n "${swap_unit}" ] && systemctl mask "${swap_unit}" >/dev/null 2>&1 || true
done < <(systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{print $1}')

cat > /etc/modules-load.d/k8s.conf <<EOF_MOD
overlay
br_netfilter
EOF_MOD

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF_SYSCTL
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF_SYSCTL

sysctl --system
install -d -m 0755 /etc/apt/keyrings

# ------------------------------------------------------------------------------
# 3. APT Repositories Setup
# ------------------------------------------------------------------------------
echo "[Step 2] Configuring APT Repositories"

download_key() {
  local url="$1"
  local out="$2"
  local tmp
  tmp="$(mktemp)"

  if ! curl -fsSL "${url}" -o "${tmp}"; then
    rm -f "${tmp}"
    echo "[ERROR] Failed to download key from: ${url}" >&2
    exit 1
  fi

  if [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    echo "[ERROR] Downloaded empty key file from: ${url}" >&2
    exit 1
  fi

  if ! gpg --dearmor -o "${out}" "${tmp}"; then
    rm -f "${tmp}" "${out}"
    echo "[ERROR] Failed to convert key to keyring: ${out}" >&2
    exit 1
  fi

  rm -f "${tmp}"
  chmod 644 "${out}"
}

download_key \
  "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  "/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

download_key \
  "https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
  "/etc/apt/keyrings/cri-o-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

# ------------------------------------------------------------------------------
# 4. Install Packages
# ------------------------------------------------------------------------------
echo "[Step 3] Installing Packages (CRI-O, Kubeadm, Kubelet, Kubectl)"
"${APT_GET[@]}" update
"${APT_GET[@]}" install -y --no-install-recommends cri-o kubelet kubeadm kubectl

apt-mark hold cri-o kubelet kubeadm kubectl

# Explicitly pin CRI-O to systemd cgroup manager for kubelet compatibility.
install -d -m 0755 /etc/crio/crio.conf.d
cat > /etc/crio/crio.conf.d/99-kubernetes.conf <<'EOF_CRIO'
[crio.runtime]
cgroup_manager = "systemd"
EOF_CRIO

systemctl daemon-reload
systemctl enable --now crio
systemctl enable kubelet

if ! systemctl is-active --quiet crio; then
  echo "[ERROR] CRI-O is not active. Check: systemctl status crio" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 5. Join Cluster
# ------------------------------------------------------------------------------
echo "[Step 4] Joining Worker Node to Cluster"

JOIN_CMD=(
  kubeadm join "${CONTROL_PLANE_ENDPOINT}"
  --token "${JOIN_TOKEN}"
  --discovery-token-ca-cert-hash "${DISCOVERY_HASH}"
  --cri-socket unix:///var/run/crio/crio.sock
)

if [ -n "${NODE_NAME}" ]; then
  JOIN_CMD+=(--node-name "${NODE_NAME}")
fi

"${JOIN_CMD[@]}"

# ------------------------------------------------------------------------------
# 6. User Convenience (.bashrc)
# ------------------------------------------------------------------------------
echo "[Step 5] Configuring Shell Convenience"

add_bash_config() {
    local target_file="$1"
    [ -f "${target_file}" ] || return 0

    if ! grep -q "### K8S-SETUP-START" "$target_file"; then
        cat <<'EOF_BASH' >> "$target_file"

### K8S-SETUP-START
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
### K8S-SETUP-END
EOF_BASH
    else
        echo " > Bash config already present in $target_file"
    fi
}

add_bash_config "$HOME/.bashrc"

REAL_USER="${SUDO_USER:-}"
if [ -z "${REAL_USER}" ]; then
    REAL_USER="$(logname 2>/dev/null || true)"
fi

if [ -n "${REAL_USER}" ] && [ "${REAL_USER}" != "root" ]; then
    USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$REAL_USER")

    if [ -f "$USER_HOME/.bashrc" ]; then
        add_bash_config "$USER_HOME/.bashrc"
        chown "$REAL_USER:$USER_GID" "$USER_HOME/.bashrc"
    fi
fi

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " [Worker Node Join Completed Successfully]"
echo "============================================================"
echo " 1. Reload your shell:  source ~/.bashrc"
echo " 2. Verify from control plane: kubectl get nodes"
echo "============================================================"
