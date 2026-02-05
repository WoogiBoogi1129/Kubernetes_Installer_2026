#!/bin/bash

# ==============================================================================
# Script Name: k8s_clean_uninstall.sh
# Description: Safely uninstalls Kubernetes from the node.
#              Prioritizes Safety & Zero Side Effects.
#              DESTRUCTIVE OPERATIONS ARE FLAGGED (Opt-in).
# Author: DevOps Engineer (Antigravity)
# Updated: Final Robust Version (Specific Guards, Strict Args, Package Logic)
# ==============================================================================

# Definite Colors for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==============================================================================
# Flags & Defaults (ALL DESTRUCTIVE OPTIONS DEFAULT TO FALSE)
# ==============================================================================
CLEANUP_CNI=false       # Removes CNI interfaces & /etc/cni/net.d
CLEANUP_ETCD=false      # Removes /var/lib/etcd
DO_AUTOREMOVE=false     # Runs apt-get autoremove

# Argument Parsing
for arg in "$@"; do
    case $arg in
        --cleanup-cni) CLEANUP_CNI=true ;;
        --cleanup-etcd) CLEANUP_ETCD=true ;;
        --autoremove) DO_AUTOREMOVE=true ;;
        --help) 
            echo "Usage: sudo $0 [OPTIONS]"
            echo "Options:"
            echo "  --cleanup-cni    Remove CNI network interfaces and config (/etc/cni/net.d)"
            echo "  --cleanup-etcd   Remove etcd data directory (/var/lib/etcd)"
            echo "  --autoremove     Run package manager autoremove (remove unused dependencies)"
            exit 0
            ;;
        *) 
            echo -e "${RED}[ERROR] Unknown option: $arg${NC}"
            echo "Use --help for usage info."
            exit 1 
            ;;
    esac
done

echo -e "${BLUE}[INFO] Kubernetes Clean Uninstall Script (Ultra-Safe Mode) Initiated...${NC}"

# ==============================================================================
# 0. Safety Checks, Detection & Confirmation
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] This script must be run as root. Please use sudo.${NC}"
  exit 1
fi

# Detect Kubernetes Traces (Guard for Network Cleanup)
# We check this BEFORE 'kubeadm reset' runs, as reset might clear some paths.
IS_K8S_DETECTED=false
if [ -d "/etc/kubernetes" ] || [ -d "/var/lib/kubelet" ] || systemctl list-unit-files --no-legend 2>/dev/null | grep -E -q '^kubelet\.service'; then
    IS_K8S_DETECTED=true
fi

echo -e "${RED}[WARNING] This script will remove Kubernetes components:${NC}"
echo -e "  - Packages: kubeadm, kubelet, kubectl, kubernetes-cni, cri-tools (Only if installed)"
echo -e "  - Configs: /etc/kubernetes, /var/lib/kubelet"
echo -e "  - Binaries: kubeadm, kubectl, kubelet (Explicit paths only)"

# Status Report
echo -e "\n${BLUE}[CONFIGURATION STATUS]${NC}"
if [ "$CLEANUP_ETCD" = true ]; then
    echo -e "  - Etcd Data (/var/lib/etcd): ${RED}DELETE${NC}"
else
    echo -e "  - Etcd Data (/var/lib/etcd): ${GREEN}KEEP (Use --cleanup-etcd to delete)${NC}"
fi

if [ "$CLEANUP_CNI" = true ]; then
    echo -e "  - Network (CNI Ifaces & Config): ${RED}DELETE${NC}"
else
    echo -e "  - Network (CNI Ifaces & Config): ${GREEN}KEEP (Use --cleanup-cni to delete)${NC}"
fi

if [ "$DO_AUTOREMOVE" = true ]; then
    echo -e "  - Package Autoremove: ${RED}YES${NC}"
else
    echo -e "  - Package Autoremove: ${GREEN}NO (Use --autoremove to enable)${NC}"
fi

read -p "Are you sure you want to proceed with the uninstallation? (y/N): " choice
case "$choice" in 
  y|Y ) echo -e "${GREEN}[INFO] User confirmed. Proceeding...${NC}";;
  * ) echo -e "${YELLOW}[INFO] Operation aborted by user.${NC}"; exit 0;;
esac

# ==============================================================================
# 1. Service Drain & Reset
# ==============================================================================
echo -e "\n${BLUE}[STEP 1/5] Resetting Kubernetes Cluster...${NC}"

# Robust check for kubelet service existence and state
if systemctl list-unit-files --no-legend 2>/dev/null | grep -E -q '^kubelet\.service'; then
    echo -e "Found kubelet.service. Stopping and disabling..."
    systemctl stop kubelet
    systemctl disable kubelet
    systemctl reset-failed kubelet 2>/dev/null
else
    echo -e "${YELLOW}[INFO] kubelet.service not found. Skipping stop/disable.${NC}"
fi

# Execute kubeadm reset
if command -v kubeadm &> /dev/null; then
    echo -e "Executing 'kubeadm reset -f'..."
    if kubeadm reset -f; then
        echo -e "${GREEN}[OK] kubeadm reset executed.${NC}"
    else
        echo -e "${RED}[WARNING] kubeadm reset failed or returned non-zero code. Proceeding with cleanup...${NC}"
    fi
else
    echo -e "${YELLOW}[SKIP] kubeadm binary not found. Skipping reset command.${NC}"
fi

# ==============================================================================
# 2. Package Purge (Install Check First)
# ==============================================================================
echo -e "\n${BLUE}[STEP 2/5] Removing Kubernetes Packages...${NC}"

TARGET_PKGS="kubeadm kubectl kubelet kubernetes-cni cri-tools"
PKGS_TO_REMOVE=""

if command -v dpkg &> /dev/null; then
    # PRE-CHECK: only purge what is installed
    echo -e "Detected apt/dpkg (Debian/Ubuntu)."
    for pkg in $TARGET_PKGS; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            PKGS_TO_REMOVE="$PKGS_TO_REMOVE $pkg"
        fi
    done
    
    if [ -n "$PKGS_TO_REMOVE" ]; then
        echo -e "Removing installed packages: $PKGS_TO_REMOVE"
        apt-get purge -y $PKGS_TO_REMOVE
        
        if [ "$DO_AUTOREMOVE" = true ]; then
            echo -e "Running autoremove..."
            apt-get autoremove -y
        fi
        echo -e "${GREEN}[OK] Packages processed.${NC}"
    else
        echo -e "${YELLOW}[SKIP] No target Kubernetes packages found installed.${NC}"
    fi

elif command -v rpm &> /dev/null; then
    # Determine Package Manager (dnf > yum)
    PKG_MGR="yum"
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    fi
    echo -e "Detected rpm based system. Using $PKG_MGR."

    for pkg in $TARGET_PKGS; do
        if rpm -q "$pkg" &> /dev/null; then
             PKGS_TO_REMOVE="$PKGS_TO_REMOVE $pkg"
        fi
    done

    if [ -n "$PKGS_TO_REMOVE" ]; then
        echo -e "Removing installed packages: $PKGS_TO_REMOVE"
        $PKG_MGR remove -y $PKGS_TO_REMOVE
        echo -e "${GREEN}[OK] Packages processed.${NC}"
    else
        echo -e "${YELLOW}[SKIP] No target Kubernetes packages found installed.${NC}"
    fi
else
    echo -e "${RED}[ERROR] Unsupported package manager.${NC}"
fi

# ==============================================================================
# 3. Network Cleanup (Opt-in + Guard)
# ==============================================================================
echo -e "\n${BLUE}[STEP 3/5] Cleaning up CNI Network Interfaces...${NC}"

if [ "$CLEANUP_CNI" = true ]; then
    if [ "$IS_K8S_DETECTED" = true ]; then
        # Precision Mode List
        TARGET_INTERFACES="cni0 flannel.1 kube-ipvs0 weave antrea-gw0"
        SKIP_REGEX="^(lo|eth[0-9]+|en[opsx][0-9]+.*|wlan[0-9]+|docker0|virbr[0-9]+|br-.*|podman[0-9]+|cilium_.*)$"

        EXISTING_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)

        for iface in $EXISTING_IFACES; do
            if [[ "$iface" =~ $SKIP_REGEX ]]; then continue; fi

            MATCH=0
            for target in $TARGET_INTERFACES; do
                if [[ "$iface" == "$target" ]]; then MATCH=1; break; fi
            done

            if [ $MATCH -eq 1 ]; then
                echo -e "${YELLOW}Deleting network interface: $iface${NC}"
                ip link set dev "$iface" down 2>/dev/null
                ip link delete "$iface" 2>/dev/null
            fi
        done
        
        # Clean /etc/cni/net.d
        if [ -d "/etc/cni/net.d" ]; then
            echo -e "Removing CNI configuration /etc/cni/net.d..."
            rm -rf /etc/cni/net.d
        fi
    else
        echo -e "${RED}[SAFETY BLOCK] No Kubernetes signs (kubelet/config) detected.${NC}"
        echo -e "${YELLOW}               Skipping interface deletion to prevent accidental network loss on non-k8s node.${NC}"
    fi
else
    echo -e "${YELLOW}[SKIP] Network cleanup & /etc/cni/net.d deletion skipped (Default).${NC}"
    echo -e "${YELLOW}       Use --cleanup-cni to delete k8s interfaces and CNI configs.${NC}"
fi

# ==============================================================================
# 4. Files Cleanup
# ==============================================================================
echo -e "\n${BLUE}[STEP 4/5] Cleaning up Configuration & Data Files...${NC}"

FILES_TO_REMOVE=(
    "/etc/kubernetes"
    "/var/lib/kubelet"
    "/var/lib/dockershim"
    "/var/run/kubernetes"
    "/etc/systemd/system/kubelet.service.d"
    "/usr/bin/kubeadm"
    "/usr/bin/kubectl"
    "/usr/bin/kubelet"
    "/usr/local/bin/kubeadm"
    "/usr/local/bin/kubectl"
    "/usr/local/bin/kubelet"
)

# Safe Etcd Removal (Opt-in)
if [ "$CLEANUP_ETCD" = true ]; then
    if [ -d "/var/lib/etcd" ]; then
        echo -e "Removing /var/lib/etcd (User requested)..."
        rm -rf "/var/lib/etcd"
    else
        echo -e "${YELLOW}[INFO] /var/lib/etcd not found, checking skipped.${NC}"
    fi
else
    if [ -d "/var/lib/etcd" ]; then
        echo -e "${YELLOW}[SKIP] /var/lib/etcd found but preserved (Default).${NC}"
        echo -e "${YELLOW}       Use --cleanup-etcd to remove it.${NC}"
    fi
fi

for target in "${FILES_TO_REMOVE[@]}"; do
    if [ -e "$target" ]; then
        echo -e "Removing $target..."
        rm -rf "$target"
    fi 
done

# Clean root kubeconfig
if [ -d "/root/.kube" ]; then rm -rf /root/.kube; fi

# Clean SUDO_USER kubeconfig
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo "~$SUDO_USER")
    if [ -d "$USER_HOME/.kube" ]; then
        rm -rf "$USER_HOME/.kube"
    fi
fi

echo -e "\n${BLUE}[STEP 5/5] Finalizing...${NC}"
systemctl daemon-reload

echo -e "${GREEN}[SUCCESS] Kubernetes uninstallation complete.${NC}"
echo -e "${YELLOW}[TIP] For a completely clean network state, a REBOOT is highly recommended.${NC}"
