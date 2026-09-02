#!/usr/bin/env bash

# ROCKY LINUX

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
  log "Updating dnf cache & installing base packages"
  $SUDO dnf makecache -y
  $SUDO dnf install -y --allowerasing curl ca-certificates dnf-plugins-core \
    socat conntrack-tools ebtables ethtool container-selinux openssl git tar
}

task_swapoff_load_modules() {
  log "Disabling swap & loading kernel modules"
  $SUDO swapoff -a
  $SUDO sed -ri 's/^([^#].*\sswap\s+sw\s+.*)$/#\1/' /etc/fstab || true
  cat <<EOF | $SUDO tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

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

task_configure_selinux() {
  log "Configuring SELinux (set to permissive) for Kubernetes compatibility"
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    $SUDO setenforce 0 || true
    $SUDO sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  else
    log "SELinux is already Disabled/Permissive, skipping"
  fi
}

task_configure_firewalld() {
  log "Disabling firewalld (lab/dev setup)"
  print_line "       Note: for production, keep firewalld enabled and open the required"
  print_line "             ports instead (10250, 30000-32767, plus CNI-specific ports)."
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    $SUDO systemctl disable --now firewalld
  else
    log "firewalld is not active, skipping"
  fi
}

task_add_docker_repo() {
  log "Adding the Docker repository (for containerd.io)"
  $SUDO dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
}

task_install_containerd() {
  log "Installing containerd & configuring SystemdCgroup"
  $SUDO dnf install -y containerd.io
  $SUDO mkdir -p /etc/containerd
  $SUDO containerd config default | $SUDO tee /etc/containerd/config.toml > /dev/null
  $SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  $SUDO systemctl enable --now containerd
  $SUDO systemctl restart containerd
}

task_add_k8s_repo() {
  log "Adding the Kubernetes repository for version ${KUBE_VERSION}"

  cat <<EOF | $SUDO tee /etc/yum.repos.d/kubernetes.repo > /dev/null
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

  $SUDO dnf makecache -y
}

task_install_kubeadm() {
  log "Installing kubelet, kubeadm, and kubectl (locking the installed versions)"
  $SUDO dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
  $SUDO systemctl enable --now kubelet
}

task_install_crictl() {
  log "Installing cri-tools (crictl) - a separate package from kubeadm/kubelet/kubectl, from the same repository"
  if command -v crictl >/dev/null 2>&1; then
    log "crictl already installed, skipping"
  else
    $SUDO dnf install -y cri-tools --disableexcludes=kubernetes
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
    print_line "  |           Kubernetes Worker Node is READY            |"
    print_line "  |                                                      |"
    print_line "  +------------------------------------------------------+"
    print_line ""
    print_line "  Project Author : Teguh Rais Rahmadi"
    print_line ""
    print_line "  [✓] Required packages installed and configured"
    print_line ""
    print_line "  Worker node setup completed successfully!"
    print_line ""
    print_line "  Final step:"
    print_line "  Run the following command manually to join this node"
    print_line "  to the Kubernetes cluster:"
    print_line ""
    print_line "    sudo kubeadm join <control-plane-endpoint> \\"
    print_line "      --token <token> \\"
    print_line "      --discovery-token-ca-cert-hash sha256:<hash>"
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
  task_configure_selinux
  task_configure_firewalld
  task_add_docker_repo
  task_install_containerd
  task_add_k8s_repo
  task_install_kubeadm
  task_install_crictl
  task_crictl_config

  print_success_message
}

main "$@"