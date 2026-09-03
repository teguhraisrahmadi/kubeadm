# Kubernetes EZ Installation **(KubeEZ)**

> *Making Kubernetes installation EZ, one script at a time. 🚀*

Simple and automated Kubernetes installation script using **kubeadm**. This project simplifies the Kubernetes installation process by automatically installing the required packages, dependencies, and system configurations with a **single script execution**. No need to manually install and configure everything step by step. Just run the script and let it handle the setup.

## Features
- **One-shot installation** — install Kubernetes with a single script
- **Automatic dependency installation** — required packages are installed automatically
- **System configuration** — prepares the system for Kubernetes
- **kubeadm-based** — uses the official Kubernetes bootstrap tool
- **Less manual work** — reduces repetitive installation and configuration steps
- **Simple & beginner-friendly** — designed to make Kubernetes installation easier

## Why KubeEZ?
Setting up Kubernetes manually can involve multiple steps, including installing dependencies, configuring the system, and installing Kubernetes components. This project aims to make that process as simple as possible.

### Manual Setup
```
Manual Setup
    ↓
Install dependencies
    ↓
Configure system
    ↓
Install Kubernetes packages
    ↓
Configure kubelet
    ↓
Initialize Kubernetes
    ↓
Lots of steps
```

### With EZ Kubernetes Installation
```
Run the script
      ↓
Kubernetes Setup
      ↓
Kubernetes Done!
```

## Getting Started
### Options
```
Usage:
  bash master.sh [--control-plane-ip IP] [--control-plane-port PORT]

Options:
  --control-plane-ip           Set the control-plane IP address (without port), e.g. 10.10.10.10.
                               If not provided and an interactive terminal is available, 
                               the script will prompt for it (up to 3 attempts).
  --control-plane-port         Override the API server port (default: ${CONTROL_PLANE_ENDPOINT_PORT})
  -h, --help                   Show this help message.
```

### Installation (Debian Default)
- Master
```
curl -fsSL https://raw.githubusercontent.com/teguhraisrahmadi/kubeadm/main/debian/master.sh | bash
```
- Master HA
```
curl -fsSL https://raw.githubusercontent.com/teguhraisrahmadi/kubeadm/main/debian/master-ha.sh | bash
```
- Worker
```
curl -fsSL https://raw.githubusercontent.com/teguhraisrahmadi/kubeadm/main/debian/worker.sh | bash
```

### Another Option
- Spesific kubernetes version
```
curl -fsSL https://raw.githubusercontent.com/teguhraisrahmadi/kubeadm/v1.3x.x/debian/master.sh | bash
```
- Spesific OS version
> Please change <**os**> to debian, ubuntu or rocky
```
curl -fsSL https://raw.githubusercontent.com/teguhraisrahmadi/kubeadm/v1.3x.x/<os>/master.sh | bash
```
- With control-plane or load balancer ip
```
curl -fsSL https://raw.githubusercontent.com/teguhraisrahmadi/kubeadm/main/debian/master.sh | bash -s -- --control-plane-ip "10.10.x.x"
```

## Package Version
- Kubernetes 1.37
- Cilium 1.20.1

## Requirements
Before running the script, make sure you have:
- **Operating system:** Debian, Ubuntu, or Rocky Linux
- **Privileges:** Root access or `sudo` privileges
- **Internet:** An active internet connection
- **Required tools:** `curl` must be installed and available in the system `PATH`
- **Environment:** A supported environment for running Kubernetes
- **System resources:** At least **2 CPU cores and 4 GB RAM**

## ⚠️ Disclaimer
This project is intended primarily for learning, development, testing, and lab environments.

Before using it in a production environment, review the script carefully and make sure the configuration matches your infrastructure and Kubernetes requirements.

Always understand what a script does before running it with sudo or root privileges.

## 🛠️ Join Node
Create token, discovery-token-ca-cert-hash, and control-plane certificate-key. Please run all of this command in master node:
- token
```
sudo kubeadm token create
```
- hash
```
sudo openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
    | openssl rsa -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -hex \
    | awk '{print "sha256:" $2}'
```
- certificate-key
```
sudo kubeadm init phase upload-certs --upload-certs 2>&1 \
    | awk '/Using certificate key:/{getline; print; exit}'
```

### ⚙️ Joining Master Node
- Run this command in new master node
> Please change <**control-plane-ha-endpoint**> to master load balancer endpoint (haproxy, nginx, etc)
```
sudo kubeadm join <control-plane-ha-endpoint> \
    --token <token> \
    --discovery-token-ca-cert-hash <hash> \
    --control-plane \
    --certificate-key <certificate-key>
```

### ⚙️ Joining Worker Node
- Run this command in new worker node
> Please change <**control-plane-endpoint**> to <**control-plane-ha-endpoint**> when using a master HA setup
```
sudo kubeadm join <control-plane-endpoint> \
    --token <token> \
    --discovery-token-ca-cert-hash <hash>
```