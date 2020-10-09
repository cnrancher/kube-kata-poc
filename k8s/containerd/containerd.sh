#!/bin/sh
set -e

BIN_DIR=/usr/local/bin
CONTAINERD="https://github.com/containerd/containerd/releases/download/v1.4.1/cri-containerd-cni-1.4.1-linux-amd64.tar.gz"

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
    if [ -x /sbin/openrc-run ]; then
        HAS_OPENRC=true
        return
    fi
    if [ -d /run/systemd ]; then
        HAS_SYSTEMD=true
        return
    fi
    fatal 'Can not find systemd or openrc to use as a process supervisor for containerd'
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

# --- define needed environment variables ---
setup_env() {
    # --- use sudo if we are not already root ---
    SUDO=sudo
    if [ $(id -u) -eq 0 ]; then
        SUDO=
    fi

    # --- use service or environment location depending on systemd/openrc ---
    if [ "${HAS_SYSTEMD}" = true ]; then
        FILE_CONTAINERD_SERVICE=/etc/systemd/system/containerd.service
    elif [ "${HAS_OPENRC}" = true ]; then
        FILE_CONTAINERD_SERVICE=/etc/init.d/containerd
    fi

    cat <<EOF | $SUDO tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    $SUDO sysctl --system
    $SUDO sysctl vm.nr_hugepages=1024
}

# --- create temporary directory and cleanup when done ---
setup_tmp() {
    TMP_DIR=$(mktemp -d -t containerd.XXXXXXXXXX)
    TMP_BIN=${TMP_DIR}/containerd.tar.gz
    cleanup() {
        code=$?
        set +e
        trap - EXIT
        rm -rf ${TMP_DIR}
        exit $code
    }
    trap cleanup INT EXIT
}

# --- download from github url ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
        curl)
            curl -o $1 -sfL $2
            ;;
        wget)
            wget -qO $1 $2
            ;;
        *)
            fatal "Incorrect executable '$DOWNLOADER'"
            ;;
    esac

    # Abort if download command failed
    [ $? -eq 0 ] || fatal 'Download failed'
}

# --- download binary from github url ---
download_binary() {
    info "Downloading binary ${CONTAINERD}"
    download ${TMP_BIN} ${CONTAINERD}
}

# --- setup permissions and move binary to system directory ---
setup_binary() {
    chmod 755 ${TMP_BIN}
    info "Installing containerd to ${BIN_DIR}"
    $SUDO tar -C / -xzf ${TMP_BIN}
    $SUDO rm -rf /etc/cni/net.d/10-containerd-net.conflist
    $SUDO chmod a+x /usr/local/bin
}

# --- verify an executable containerd binary is installed ---
verify_containerd_is_executable() {
    if [ ! -x ${BIN_DIR}/containerd ]; then
        fatal "Executable containerd binary not found at ${BIN_DIR}/containerd"
    fi
}

# --- verify existence of network downloader executable ---
verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    [ -x "$(which $1)" ] || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

# --- download and verify containerd ---
download_and_verify() {
    setup_verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    download_binary
    setup_binary
}

# --- create containerd config ---
create_containerd_config() {
    info "Creating config file /etc/containerd/config.toml"
    $SUDO mkdir -p /etc/containerd
    $SUDO cat > /etc/containerd/config.toml << EOF
[plugins.cri.cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"
  max_conf_num = 1
  conf_template = ""
[plugins.cri.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
EOF
}

# --- write systemd service file ---
create_systemd_service_file() {
    info "systemd: Creating service file containerd"
    $SUDO tee /etc/systemd/system/containerd.service >/dev/null << EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
KillMode=process
Delegate=yes
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

EOF
}

# --- write openrc service file ---
create_openrc_service_file() {
    LOG_FILE=/var/log/containerd.log

    info "openrc: Creating service file ${FILE_CONTAINERD_SERVICE}"
    $SUDO tee ${FILE_CONTAINERD_SERVICE} >/dev/null << EOF
#!/sbin/openrc-run

depend() {
    after network-online
    want cgroups
}

start_pre() {
    /sbin/modprobe br_netfilter
    /sbin/modprobe overlay
}

supervisor=supervise-daemon
name=containerd
command="/usr/local/bin/containerd"
command_args=" >>${LOG_FILE} 2>&1"

output_log=${LOG_FILE}
error_log=${LOG_FILE}

pidfile="/var/run/containerd.pid"
respawn_delay=5
respawn_max=0

set -o allexport
if [ -f /etc/environment ]; then source /etc/environment; fi
set +o allexport
EOF
    $SUDO chmod 0755 ${FILE_CONTAINERD_SERVICE}

    $SUDO tee /etc/logrotate.d/containerd >/dev/null << EOF
${LOG_FILE} {
	missingok
	notifempty
	copytruncate
}
EOF
}

# --- write systemd or openrc service file ---
create_service_file() {
    [ "${HAS_SYSTEMD}" = true ] && create_systemd_service_file
    [ "${HAS_OPENRC}" = true ] && create_openrc_service_file
    return 0
}

# --- enable and start systemd service ---
systemd_enable() {
    info "systemd: Enabling containerd unit"
    $SUDO systemctl enable ${FILE_CONTAINERD_SERVICE} >/dev/null
    $SUDO systemctl daemon-reload >/dev/null
    info "systemd: Starting containerd"
    $SUDO systemctl restart containerd
}

# --- enable and start openrc service ---
openrc_enable() {
    info "openrc: Enabling containerd service for default runlevel"
    $SUDO rc-update add containerd default >/dev/null
    info "openrc: Starting containerd"
    $SUDO ${FILE_CONTAINERD_SERVICE} restart
}

# --- startup systemd or openrc service ---
service_enable_and_start() {
    [ "${HAS_SYSTEMD}" = true ] && systemd_enable
    [ "${HAS_OPENRC}" = true ] && openrc_enable
    return 0
}

# --- run the install process --
{
    verify_system
    setup_env
    download_and_verify
    create_containerd_config
    create_service_file
    service_enable_and_start
}
