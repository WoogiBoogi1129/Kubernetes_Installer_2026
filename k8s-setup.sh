#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Kubernetes Install Script (Kubeadm + CRI-O + Cilium)
#
# Target OS: Ubuntu/Debian based systems
# Role: Single Control Plane setup
# Security: Enforces Root verification, strict error handling, dependency checks
# ==============================================================================

# Error Trap with Line Number and Command
trap 'echo "[ERROR] Script failed at line ${LINENO} near command: ${BASH_COMMAND}" >&2' ERR

# ------------------------------------------------------------------------------
# 0. Safety & Environment Checks
# ------------------------------------------------------------------------------
# 0.1 Root Check
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] This script must be run as root." >&2
  echo "Usage: sudo -i, then run this script." >&2
  exit 1
fi

umask 022

# 0.2 Existing Installation Check
if [ -f "/etc/kubernetes/admin.conf" ] || [ -d "/var/lib/etcd" ]; then
    echo "[ERROR] Detected existing Kubernetes configuration." >&2
    echo "Files found: /etc/kubernetes/admin.conf OR /var/lib/etcd" >&2
    echo "Please run 'kubeadm reset' or clean up the environment before running this script." >&2
    exit 1
fi

# 0.3 Kernel Version Check (Strict Mode)
# Cilium 1.18+ requires Linux Kernel 5.10+
CURRENT_KERNEL_FULL=$(uname -r)
CURRENT_KERNEL_MAIN=$(echo "$CURRENT_KERNEL_FULL" | cut -d- -f1) # Extracts 6.8.0 from 6.8.0-31-generic
MIN_KERNEL="5.10"

if dpkg --compare-versions "$CURRENT_KERNEL_MAIN" lt "$MIN_KERNEL"; then
    echo "[ERROR] Cilium 1.18.x strictly requires Linux Kernel $MIN_KERNEL or higher." >&2
    echo "        Current Kernel: $CURRENT_KERNEL_MAIN ($CURRENT_KERNEL_FULL)" >&2
    echo "        Please upgrade your kernel before proceeding." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Configuration & User Input
# ------------------------------------------------------------------------------
# Default to v1.35 (Latest Stable)
DEFAULT_K8S_VER="v1.35"
# Cilium Version: Using 1.18.6 (Latest patch in 1.18 series as of context) for better k8s 1.35 compatibility
CILIUM_VERSION="1.18.6"
CIDR="10.85.0.0/16"

echo "============================================================"
echo " Kubernetes Installation Setup"
echo "============================================================"
echo -n "Enter Kubernetes Version to install (e.g., v1.35) [Default: ${DEFAULT_K8S_VER}]: "
read -r USER_INPUT

# Version Selection Logic
if [ -z "$USER_INPUT" ]; then
  KUBERNETES_VERSION="${DEFAULT_K8S_VER}"
else
  # Auto-prepend 'v' if missing
  if [[ "${USER_INPUT}" != v* ]]; then
    KUBERNETES_VERSION="v${USER_INPUT}"
  else
    KUBERNETES_VERSION="${USER_INPUT}"
  fi
fi

# Regex Validation (Strictly v1.XX)
if [[ ! "${KUBERNETES_VERSION}" =~ ^v1\.[0-9]{2}$ ]]; then
  echo "[ERROR] Invalid version format: ${KUBERNETES_VERSION}. Expected format: v1.XX (e.g., v1.35)" >&2
  exit 1
fi

# Sync CRI-O version with Kubernetes version
CRIO_VERSION="${KUBERNETES_VERSION}"

echo ""
echo "------------------------------------------------------------"
echo " [Configuration Confirm]"
echo " - Kubernetes Version : ${KUBERNETES_VERSION}"
echo " - CRI-O Version      : ${CRIO_VERSION}"
echo " - Cilium Version     : ${CILIUM_VERSION}"
echo " - Pod CIDR           : ${CIDR}"
echo " - Kernel Version     : ${CURRENT_KERNEL_FULL} (OK)"
echo "------------------------------------------------------------"
echo "Starting installation in 3 seconds... (Press Ctrl+C to cancel)"
sleep 3
echo ""

# ------------------------------------------------------------------------------
# 2. System Preparation
# ------------------------------------------------------------------------------
echo "[Step 1] System Configuration (Deps, Swap, Modules, Sysctl)"

# 2.1 Install Critical Dependencies
# Added: conntrack, socat, iproute2, iptables which are critical for K8s networking
apt-get update
apt-get install -y \
    software-properties-common curl gnupg2 bash-completion \
    apt-transport-https ca-certificates \
    conntrack socat iproute2 iptables ebtables

# 2.2 Disable Swap (Permanent)
if grep -q "swap" /etc/fstab; then
    echo " > Disabling swap in /etc/fstab (Backup created at /etc/fstab.bak)..."
    sed -ri.bak '/\sswap\s/s/^/#/' /etc/fstab
fi
swapoff -a

# 2.3 Kernel Modules (Permanent Load)
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 2.4 Sysctl Params (Permanent)
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 2.5 Prepare Safe Keyring Directory
install -d -m 0755 /etc/apt/keyrings

# ------------------------------------------------------------------------------
# 3. APT Repositories Setup
# ------------------------------------------------------------------------------
echo "[Step 2] Configuring APT Repositories"

# Kubernetes Official Repo (pkgs.k8s.io)
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

# CRI-O Official Repo
curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

# ------------------------------------------------------------------------------
# 4. Install Packages
# ------------------------------------------------------------------------------
echo "[Step 3] Installing Packages (CRI-O, Kubeadm, Kubelet, Kubectl)"
apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl

# Prevent accidental upgrades
# Note: In strict production environment, you might only hold kube components and let CRI-O update via patches,
# but holding all is safer for consistency without manual intervention.
apt-mark hold cri-o kubelet kubeadm kubectl

# Enable CRI-O
systemctl daemon-reload
systemctl enable --now crio

# ------------------------------------------------------------------------------
# 5. Cluster Initialization
# ------------------------------------------------------------------------------
echo "[Step 4] Initializing Kubernetes Cluster"
kubeadm init --pod-network-cidr="${CIDR}" --cri-socket=unix:///var/run/crio/crio.sock

# ------------------------------------------------------------------------------
# 5.1 Verification Wait Loop
# ------------------------------------------------------------------------------
echo " > Waiting for API Server to be ready..."
export KUBECONFIG=/etc/kubernetes/admin.conf

# Wait up to 60 seconds
MAX_RETRIES=30
for ((i=1; i<=MAX_RETRIES; i++)); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
        echo " > API Server is READY."
        break
    fi
    echo "   ... waiting for API server ($i/$MAX_RETRIES)"
    sleep 2
done

if ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
    echo "[ERROR] API Server did not become ready in time." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Kubeconfig Setup
# ------------------------------------------------------------------------------
echo "[Step 5] Setting up Kubeconfig"

mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$SUDO_USER")
    
    echo " > Copying kubeconfig to sudo user ($SUDO_USER)..."
    mkdir -p "$USER_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown -R "$SUDO_USER:$USER_GID" "$USER_HOME/.kube"
    chmod 600 "$USER_HOME/.kube/config"
fi

# ------------------------------------------------------------------------------
# 7. Install Tools (Helm & Cilium)
# ------------------------------------------------------------------------------
echo "[Step 6] Installing Helm"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

echo "[Step 7] Installing Cilium"
# 7.1 Install Cilium CLI with robust error check (-fsSL)
# Fetching latest stable version strictly
CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

echo " > Downloading Cilium CLI ${CILIUM_CLI_VERSION}..."
curl -L --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
tar xzvf cilium-linux-${CLI_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# 7.2 Install Cilium CNI
# Using updated version 1.18.6 for better stability with newer K8s
# Explicitly setting ipam.mode=kubernetes to match kubeadm pod-network-cidr
echo " > Installing Cilium CNI (Version: ${CILIUM_VERSION}) with ipam.mode=kubernetes..."
cilium install --version "${CILIUM_VERSION}" \
  --helm-set ipam.mode=kubernetes

echo " > Waiting for Cilium status..."
cilium status --wait

# ------------------------------------------------------------------------------
# 8. User Convenience (.bashrc)
# ------------------------------------------------------------------------------
echo "[Step 8] Configuring Shell Convenience"

add_bash_config() {
    local target_file="$1"
    if ! grep -q "### K8S-SETUP-START" "$target_file"; then
        cat <<'EOF' >> "$target_file"

### K8S-SETUP-START
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
### K8S-SETUP-END
EOF
    else
        echo " > Bash config already present in $target_file"
    fi
}

add_bash_config "$HOME/.bashrc"

if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_GID=$(id -gn "$SUDO_USER") # Get group ID
    
    # Check if file exists before writing
    if [ -f "$USER_HOME/.bashrc" ]; then
        add_bash_config "$USER_HOME/.bashrc"
        # Since we append as root, we should ensure ownership isn't messed up, 
        # but appending usually preserves ownership if file exists. 
        # Just in case, safe to re-chown.
        chown "$SUDO_USER:$USER_GID" "$USER_HOME/.bashrc"
    fi
fi

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " [Installation Completed Successfully]"
echo "============================================================"
echo " 1. Reload your shell:  source ~/.bashrc"
echo " 2. Check Nodes:        kubectl get nodes"
echo " 3. Check Pods:         kubectl get pods -A"
echo "============================================================"
