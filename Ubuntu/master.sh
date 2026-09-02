#!/usr/bin/env bash

# UBUNTU

set -euo pipefail

########################################
# =========== VARIABLES ================
########################################
KUBE_VERSION="v1.37"
KUBERNETES_FULL_VERSION="1.37.0"
KUBEADM_API_VERSION="kubeadm.k8s.io/v1beta4"
USER_PATH="/home/kube-user"
KUBE_USER="kube-user"
CILIUM_VERSION="1.20.1"
CILIUM_CIDR="10.12.0.0/16"
CILIUM_WAIT_SECONDS=30
POD_SUBNET="10.12.0.0/16"
ROOT_KUBE_DIR="/root/.kube"

CONTROL_PLANE_ENDPOINT_PORT="6443"   # Default port API server

# Leave empty ("") if you want to provide the value via the --control-plane-ip argument or an interactive prompt.
# Set it directly here if you want the script to run automatically without any prompts, for example:
# CONTROL_PLANE_ENDPOINT_IP="10.10.10.10"
CONTROL_PLANE_ENDPOINT_IP=""

########################################
# === DERIVED (do not edit manually) ===
########################################
KUBEADM_CONFIG_PATH="${USER_PATH}/kubeadm-config.yaml"
KUBEADM_INIT_LOG="${USER_PATH}/.kubeadm-init.out"
CILIUM_MANIFEST_OUT="${USER_PATH}/.cilium.yaml"
# CONTROL_PLANE_ENDPOINT is automatically constructed from the IP and PORT inside ensure_control_plane_endpoint()

########################################
# =========== HELPER ===================
########################################
log() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }
print_line() { printf '%s\n' "$*"; }

require_root_helper() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi
}

# Parse CLI arguments; called from main() as: parse_args "$@"
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --control-plane-ip)
        CONTROL_PLANE_ENDPOINT_IP="${2:-}"
        shift 2
        ;;
      --control-plane-ip=*)
        CONTROL_PLANE_ENDPOINT_IP="${1#*=}"
        shift
        ;;
      --control-plane-port)
        CONTROL_PLANE_ENDPOINT_PORT="${2:-}"
        shift 2
        ;;
      --control-plane-port=*)
        CONTROL_PLANE_ENDPOINT_PORT="${1#*=}"
        shift
        ;;
      -h|--help)
        cat <<EOF
Usage:
  bash master.sh [--control-plane-ip IP] [--control-plane-port PORT]

Options:
  --control-plane-ip           Set the control-plane IP address (without port), e.g. 10.10.10.10.
                               If not provided and an interactive terminal is available, 
                               the script will prompt for it (up to 3 attempts).
  --control-plane-port         Override the API server port (default: ${CONTROL_PLANE_ENDPOINT_PORT})
  -h, --help                   Show this help message.
EOF
        exit 0
        ;;
      *)
        err "Unknown argument: $1 (use -h for help)"
        exit 1
        ;;
    esac
  done
}

# Ensure CONTROL_PLANE_ENDPOINT_IP is set, then combine it with the port to construct CONTROL_PLANE_ENDPOINT.
# - If the IP is already set (via a hardcoded variable or CLI argument), continue automatically without prompting.
# - If empty and no TTY is available (e.g. automation without arguments), fail immediately with a clear error message.
# - If empty and running interactively (TTY available), prompt via /dev/tty, with a maximum of 3 attempts.
ensure_control_plane_endpoint() {
  if [ -n "$CONTROL_PLANE_ENDPOINT_IP" ]; then
    log "CONTROL_PLANE_ENDPOINT_IP: ${CONTROL_PLANE_ENDPOINT_IP}"
  elif [ ! -e /dev/tty ]; then
    err "No interactive terminal (/dev/tty) is available to display the prompt."
    err "Run the script with the --control-plane-ip argument, for example:"
    err "  ... | bash -s -- --control-plane-ip \"10.10.10.10\""
    exit 1
  else
    local attempt=1
    local input=""
    while [ "$attempt" -le 3 ]; do
      read -r -p "Enter the master IP (default port is already set to ${CONTROL_PLANE_ENDPOINT_PORT}), e.g. 10.10.10.10: " input < /dev/tty || true
      if [ -n "$input" ]; then
        CONTROL_PLANE_ENDPOINT_IP="$input"
        break
      fi
      err "Input cannot be empty. Attempt ${attempt}/3."
      attempt=$((attempt + 1))
    done

    if [ -z "$CONTROL_PLANE_ENDPOINT_IP" ]; then
      err "Failed to get the master IP after 3 attempts."
      err "Run this script again, set the variable directly, or use the --control-plane-ip argument."
      exit 1
    fi
  fi

  CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT_IP}:${CONTROL_PLANE_ENDPOINT_PORT}"
  log "CONTROL_PLANE_ENDPOINT: ${CONTROL_PLANE_ENDPOINT}"
}

########################################
# =========== TASKS ====================
########################################

task_create_kube_user() {
  log "Check/create user ${KUBE_USER}"
  if id "$KUBE_USER" &>/dev/null; then
    log "User ${KUBE_USER} already exists, skipping user creation"
  else
    # -m  : create the home directory
    # -s  : set the default shell to bash
    # without setting a password -> the account is locked for password-based login,
    # but it can still be accessed via 'sudo su - kube-user' from root/sudoers (the target user's password is not required)
    $SUDO useradd -m -s /bin/bash -d "$USER_PATH" "$KUBE_USER"
    log "User ${KUBE_USER} created successfully with home directory ${USER_PATH}"
  fi
}

task_update_install_packages() {
  log "Updating apt & installing basic packages"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -y
  $SUDO apt-get install -y curl gpg apt-transport-https vim git wget \
    lsb-release ca-certificates
}

task_swapoff_load_modules() {
  log "Disabling swap & loading kernel modules"
  $SUDO swapoff -a
  $SUDO sed -ri 's/^([^#].*\sswap\s+sw\s+.*)$/#\1/' /etc/fstab || true
  $SUDO modprobe overlay
  $SUDO modprobe br_netfilter
}

task_configure_sysctl() {
  log "Configuring sysctl for Kubernetes traffic"
  local conf="/etc/sysctl.d/kubernetes.conf"
  local conf_default="${conf}.default"

  [ -f "$conf" ] || $SUDO touch "$conf"
  [ -f "$conf_default" ] || $SUDO cp "$conf" "$conf_default"
  $SUDO cp "$conf_default" "$conf"

  {
    echo "net.bridge.bridge-nf-call-ip6tables = 1"
    echo "net.bridge.bridge-nf-call-iptables = 1"
    echo "net.ipv4.ip_forward = 1"
  } | $SUDO tee -a "$conf" > /dev/null

  $SUDO sysctl --system
}

task_add_docker_repo() {
  log "Adding the Docker repository (for containerd.io) & GPG key"
  $SUDO install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  fi

  $SUDO tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

task_install_containerd() {
  log "Installing containerd & configuring SystemdCgroup"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update
  $SUDO apt-get install -y containerd.io

  $SUDO containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null
  $SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  $SUDO systemctl restart containerd
}

task_add_k8s_repo() {
  log "Adding the Kubernetes repository for version ${KUBE_VERSION}"
  export DEBIAN_FRONTEND=noninteractive

  if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/Release.key" | \
      $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  fi

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/ /" | \
    $SUDO tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

  $SUDO apt-get update
}

task_install_kubeadm() {
  log "Installing kubelet, kubeadm, and kubectl (holding the installed versions)"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get install -y kubelet kubeadm kubectl
  $SUDO apt-mark hold kubelet kubeadm kubectl
}

task_install_crictl() {
  log "Installing cri-tools (crictl) - a separate package from kubeadm/kubelet/kubectl, from the same repository"
  if command -v crictl >/dev/null 2>&1; then
    log "crictl already installed, skipping"
  else
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get install -y cri-tools
  fi
}

task_generate_kubeadm_config() {
  log "Creating kubeadm-config.yaml at ${KUBEADM_CONFIG_PATH}"

  if $SUDO test -d "$USER_PATH"; then
    log "Folder ${USER_PATH} already exists, skipping folder creation"
  else
    $SUDO mkdir -p "$USER_PATH"
    log "Folder ${USER_PATH} created successfully"
  fi

  cat <<EOF | $SUDO tee "$KUBEADM_CONFIG_PATH" > /dev/null
apiVersion: ${KUBEADM_API_VERSION}
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_FULL_VERSION}
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT}"
networking:
  podSubnet: ${POD_SUBNET}
EOF

  $SUDO chmod 0664 "$KUBEADM_CONFIG_PATH"
}

task_init_master() {
  log "Initializing the master node (kubeadm init)"
  if $SUDO test -f "$KUBEADM_INIT_LOG"; then
    log "File ${KUBEADM_INIT_LOG} already exists, skipping kubeadm init"
  else
    $SUDO kubeadm init --config="$KUBEADM_CONFIG_PATH" --upload-certs | $SUDO tee "$KUBEADM_INIT_LOG"
    $SUDO rm -f "$KUBEADM_CONFIG_PATH"
  fi
  log "To join additional worker/control-plane nodes, copy the 'kubeadm join ...' command from: ${KUBEADM_INIT_LOG}"
}

task_setup_kubeconfig() {
  log "Setting up root-only kubeconfig at ${ROOT_KUBE_DIR}/config"

  if $SUDO test -d "$ROOT_KUBE_DIR"; then
    log "Folder ${ROOT_KUBE_DIR} already exists, skipping folder creation"
  else
    $SUDO mkdir -p "$ROOT_KUBE_DIR"
    log "Folder ${ROOT_KUBE_DIR} created successfully"
  fi

  if ! $SUDO test -f "${ROOT_KUBE_DIR}/config"; then
    $SUDO cp -i /etc/kubernetes/admin.conf "${ROOT_KUBE_DIR}/config"
  else
    log "${ROOT_KUBE_DIR}/config already exists, skipping"
  fi
  $SUDO chown root:root "${ROOT_KUBE_DIR}/config"
  $SUDO chmod 600 "${ROOT_KUBE_DIR}/config"
}

task_install_helm() {
  log "Installing Helm"
  if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
  else
    log "Helm is already installed, skipping"
  fi
}

task_install_cilium() {
  log "Install CNI Cilium versi ${CILIUM_VERSION}"
  export KUBECONFIG="${ROOT_KUBE_DIR}/config"

# idempotent: if the release already exists, skip it (instead of treating it as an error like the previous version)
  if $SUDO helm status cilium -n kube-system >/dev/null 2>&1; then
    log "Helm release 'cilium' is already installed, skipping installation"
    log "(To update it, run manually: helm upgrade cilium cilium/cilium --version <new_version> -n kube-system)"
  else
    log "Waiting ${CILIUM_WAIT_SECONDS} seconds for the API server & kubelet to stabilize after kubeadm init..."
    print_line "       Note: Cilium may fail to install if Kubernetes is not ready yet."
    print_line "             If that happens, simply run the script again."
    sleep "${CILIUM_WAIT_SECONDS}"

    $SUDO helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    $SUDO helm repo update

    $SUDO helm template cilium cilium/cilium \
      --version "${CILIUM_VERSION}" \
      --namespace kube-system \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="${CILIUM_CIDR}" \
      | $SUDO tee "${CILIUM_MANIFEST_OUT}" >/dev/null

    $SUDO helm install cilium cilium/cilium \
      --version "${CILIUM_VERSION}" \
      --namespace kube-system \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="${CILIUM_CIDR}"
  fi
}

task_crictl_and_show_pods() {
  log "Configuring crictl & checking pods in kube-system"
  $SUDO crictl config \
    --set runtime-endpoint=unix:///run/containerd/containerd.sock \
    --set image-endpoint=unix:///run/containerd/containerd.sock

  export KUBECONFIG="${ROOT_KUBE_DIR}/config"
  $SUDO kubectl -n kube-system get pod
}

print_success_message() {
    log "For your information."
    print_line ""
    print_line "  +------------------------------------------------------+"
    print_line "  |                                                      |"
    print_line "  |                      CONGRATS!                       |"
    print_line "  |                                                      |"
    print_line "  |           Kubernetes Master Node is READY            |"
    print_line "  |                                                      |"
    print_line "  +------------------------------------------------------+"
    print_line ""
    print_line "  Project Author : Teguh Rais Rahmadi"
    print_line ""
    print_line "  [✓] Required packages installed and configured"
    print_line ""
    print_line "  Master node setup completed successfully!"
    print_line "  - kubeconfig root : ${ROOT_KUBE_DIR}/config"
    print_line "  - To join an additional master or worker node, check and manually copy the 'kubeadm join ...' command from: ${KUBEADM_INIT_LOG}"
    print_line ""
    print_line "  Master:"
    print_line "  Run the following command manually:"
    print_line ""
    print_line "    sudo kubeadm join <control-plane-endpoint> \\"
    print_line "      --token <token> \\"
    print_line "      --discovery-token-ca-cert-hash sha256:<hash> \\"
    print_line "      --control-plane \\"
    print_line "      --certificate-key <certificate-key>"
    print_line ""
    print_line "  Worker:"
    print_line "  Run the following command manually:"
    print_line ""
    print_line "    sudo kubeadm join <control-plane-endpoint> \\"
    print_line "      --token <token> \\"
    print_line "      --discovery-token-ca-cert-hash sha256:<hash> \\"
    print_line "      --control-plane \\"
    print_line "      --certificate-key <certificate-key>"
    print_line ""
}

########################################
# =========== MAIN =====================
########################################
main() {
  parse_args "$@"
  require_root_helper
  ensure_control_plane_endpoint

  task_create_kube_user
  task_update_install_packages
  task_swapoff_load_modules
  task_configure_sysctl
  task_add_docker_repo
  task_install_containerd
  task_add_k8s_repo
  task_install_kubeadm
  task_install_crictl
  task_generate_kubeadm_config
  task_init_master
  task_setup_kubeconfig
  task_install_helm
  task_install_cilium
  task_crictl_and_show_pods

  print_success_message
}

main "$@"