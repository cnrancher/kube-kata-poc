#!/bin/sh
set -e

BIN_DIR=/usr/bin

# --- helper functions for logs ---
info()
{
    echo '[INFO] ' "$@"
}
warn()
{
    echo '[WARN] ' "$@" >&2
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

# --- fatal if no systemd or openrc ---
verify_system() {
    if [ -d /run/systemd ]; then
        HAS_SYSTEMD=true
        return
    fi
    fatal 'Can not find systemd to use as a process supervisor for kubernetes'
}

# --- set arch and suffix, fatal if architecture not supported ---
setup_verify_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        amd64)
            ARCH=amd64
            SUFFIX=
            ;;
        x86_64)
            ARCH=amd64
            SUFFIX=
            ;;
        *)
            fatal "Unsupported architecture $ARCH"
    esac
}


# --- setup permissions and move binary to system directory ---
setup_binary() {
    info "Installing kubeadm to ${BIN_DIR}"
    $SUDO apt-get update && sudo apt-get install -y apt-transport-https curl
    $SUDO curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | $SUDO apt-key add -
    $SUDO cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
    $SUDO apt-get update && $SUDO apt-get install -y kubelet kubeadm kubectl && $SUDO apt-mark hold kubelet kubeadm kubectl
    verify_kubeadm_is_executable
    $SUDO mkdir -p  /etc/systemd/system/kubelet.service.d/
    $SUDO cat << EOF | sudo tee /etc/systemd/system/kubelet.service.d/0-containerd.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --runtime-request-timeout=15m --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
    $SUDO systemctl daemon-reload
    $SUDO kubeadm init --cri-socket /run/containerd/containerd.sock --pod-network-cidr=10.244.0.0/16
    $SUDO mkdir -p $HOME/.kube && $SUDO cp -i /etc/kubernetes/admin.conf $HOME/.kube/config && $SUDO chown $(id -u):$(id -g) $HOME/.kube/config
    $SUDO curl -o kube-flannel.yml -sfL https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
    $SUDO sed 's/vxlan/host-gw/' -i kube-flannel.yml
    kubectl apply -f kube-flannel.yml
    kubectl taint nodes --all node-role.kubernetes.io/master-
    $SUDO sed 's/- --port=0/# - --port=0/' -i /etc/kubernetes/manifests/kube-controller-manager.yaml
    $SUDO sed 's/- --port=0/# - --port=0/' -i /etc/kubernetes/manifests/kube-scheduler.yaml
    $SUDO systemctl restart kubelet
}

# --- verify an executable kubeadm binary is installed ---
verify_kubeadm_is_executable() {
    if [ ! -x ${BIN_DIR}/kubeadm ]; then
        fatal "Executable kubeadm binary not found at ${BIN_DIR}/kubeadm"
    fi
}


# --- download and verify kubeadm ---
download_and_verify() {
    setup_verify_arch
    setup_binary
}

# --- run the install process --
{
    verify_system
    download_and_verify
}
