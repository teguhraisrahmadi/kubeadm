#!/usr/bin/env bash

# UBUNTU

set -euo pipefail

########################################
# =========== VARIABLES ================
########################################
KUBE_VERSION="v1.37"
USER_PATH="/home/kube-user"
KUBE_USER="kube-user"

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

########################################
# =========== TASKS ====================
########################################

task_create_kube_user() {
  log "Check/create user ${KUBE_USER}"
  if id "$KUBE_USER" &>/dev/null; then
    log "User ${KUBE_USER} already exists, skipping user creation"
  else
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

task_crictl_config() {
  log "Configuring crictl"
  $SUDO crictl config \
    --set runtime-endpoint=unix:///run/containerd/containerd.sock \
    --set image-endpoint=unix:///run/containerd/containerd.sock
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
    print_line ""
    print_line "  Final step:"
    print_line "  Run the following command manually to join this node"
    print_line "  to the Kubernetes cluster:"
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
  require_root_helper

  task_create_kube_user
  task_update_install_packages
  task_swapoff_load_modules
  task_configure_sysctl
  task_add_docker_repo
  task_install_containerd
  task_add_k8s_repo
  task_install_kubeadm
  task_install_crictl
  task_crictl_config

  print_success_message
}

main "$@"