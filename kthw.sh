#!/bin/bash

# 3-node Kubernetes the Hard Way on Raspberry Pi 5
# All functions marked # N. should be run on the local system

if ! (return 0 2>/dev/null); then
    echo "Usage: source $0"
    echo
    # grep -E '^#([^!#]|$)' "$0"
    cat <<'EOF'
After sourcing the script, run the functions marked with an # N. comment in the order they appear

EOF
    grep -A1 -E '^# [[:digit:]]+\.' "$0" | sed 's/^function //;s/ ().*//'
    exit 1
fi

source config.sh

function kthw-darwin-setup () {
    local packages=(
        gnu-tar openssl jq yq parallel
        libvirt       # for virsh
        virt-manager  # for virt-install
        rsync         # for --mkpath
        coreutils     # for install -D
    )

    # install packages
    brew list "${packages[@]}" >/dev/null 2>/dev/null || brew install "${packages[@]}"

    # install kubectl
    kubectl_version=$(head -n1 downloads.txt | sed -E 's|.*/v([0-9]+\.[0-9]+)\.[0-9]+.*|\1|')
    brew install "kubernetes-cli@${kubectl_version}"
    brew link --force --overwrite "kubernetes-cli@${kubectl_version}"

    if [[ "$KTHW_SSH_CA_KEY" == *"Secretive.SecretAgent"* ]]; then
        SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
    fi

    LIBVIRT_DEFAULT_URI=qemu+ssh://pi@${KTHW_PI_HOST}/system
    PATH="$(brew --prefix coreutils)/libexec/gnubin":$PATH  # for install -D
    KUBECONFIG=admin.kubeconfig

    export PATH LIBVIRT_DEFAULT_URI SSH_AUTH_SOCK KUBECONFIG
}

function kthw-linux-setup () {
    local packages=(
        rsync jq yq parallel
        virtinst  # for virt-install
        libvirt-clients  # for virsh
    )

    if ! command -v apt-get >/dev/null; then
        echo "Only Debian-based systems are supported at the moment"
        echo "Please install the packages for the following tools manually: jq yq parallel virsh virt-install rsync"
        return 1
    fi

    # install packages
    sudo apt-get install -y --no-install-recommends virtinst rsync jq yq

    LIBVIRT_DEFAULT_URI=qemu+ssh://pi@${KTHW_PI_HOST}/system

    export LIBVIRT_DEFAULT_URI
}

#
# 1. local environment setup
function kthw-setup () {
    # shellcheck disable=SC1091
    source "config.sh"

    case "$OSTYPE" in
        linux*) kthw-linux-setup ;;
        darwin*) kthw-darwin-setup ;;
        *) echo "Unsupported OS: $OSTYPE"; return 1 ;;
    esac
}

# TODO verify on a fresh install of Raspberry Pi OS
# This function is executed remotely on the Raspberry Pi using GNU parallel
# It installs and configures libvirt, and downloads the Debian qcow2 image.
function kthw-rpi-remote-setup () {  # Debian qcow2 image URL
    set -xEeuo pipefail
    sudo apt-get -y install libvirt-daemon-system

    if ! groups | grep -q libvirt; then
        sudo usermod -a -G libvirt,kvm pi
        echo "User 'pi' added to libvirt group. Logging out. Please re-run kthw-rpi-setup."
        loginctl terminate-user pi
    fi

    IMAGE_URL="$1"
    VOL="$(basename "$1")"
    IMG="/tmp/$VOL"

    export LIBVIRT_DEFAULT_URI=qemu:///system
    if ! virsh pool-info default >/dev/null 2>&1; then
        sudo mkdir -p /var/lib/libvirt/images
        virsh pool-define-as default dir --target /var/lib/libvirt/images
        virsh pool-start default
        virsh pool-autostart default
    fi

    if ! virsh vol-info --pool default "$VOL" >/dev/null 2>&1; then
        curl -C- --output-dir /tmp -LO "$IMAGE_URL"
        virsh pool-info default
        virsh vol-create-as default "$VOL" "$(qemu-img info --output json "$IMG" | jq -r .\"virtual-size\")"
        virsh vol-upload --pool default --vol "$VOL" --file "$IMG"
    fi
}
export -f kthw-rpi-remote-setup

#
# 2. Raspberry Pi OS setup (install packages, set up libvirt, download Debian QCOW2 image)
function kthw-rpi-setup () {
    # https://www.gnu.org/software/parallel/parallel_tutorial.html#transferring-environment-variables-and-functions
    parallel --no-notice -j1 --env kthw-rpi-remote-setup -S "$KTHW_PI_HOST" kthw-rpi-remote-setup ::: "$KTHW_DEBIAN_IMAGE"
}

#
# 3. download binaries listed in downloads.txt
function kthw-dl () (
    set -Eeuo pipefail
    test -f "downloads.txt"

    xargs -P8 -n1 curl -R -C- --create-dirs --output-dir downloads/ -sLO < downloads.txt
)

function kthw-ssh-cleanup () {
    test -d "$1" || return
    local dir=$1

    rm -f "$dir/ssh_host_ed25519_key" "$dir/ssh_host_ed25519_key-cert.pub" "$dir/ssh_host_ed25519_key.pub"
    rmdir "$dir"
}

# augment cloud-config in configs/debian12.yaml
function kthw-cloud-config () (  # hostname
    set -Eeuo pipefail

    hostname=$1
    dir="$(mktemp -d -t "${hostname}-XXXXXXXXXX")"
    trap 'kthw-ssh-cleanup "$dir"' EXIT

    # shellcheck disable=SC2034
    export host_cert="$dir/ssh_host_ed25519_key-cert.pub"
    export host_key="$dir/ssh_host_ed25519_key"
    export KTHW_SSH_CA_KEY

    # $'' is used to preserve newlines in the string
    if [[ "${KTHW_APT_CACHER_NG:-}" ]]; then
        apt_proxy=$'Acquire::http::Proxy "'$KTHW_APT_CACHER_NG$'";\n'
    else
        apt_proxy=$'// no apt-cacher-ng proxy //\n'
    fi

    export apt_proxy

    # - generate SSH host key pair and sign with CA key hosted in ssh agent
    # - the CA key is identified by the CA public key contained in the file $KTHW_SSH_CA_KEY
    # - ~/.ssh/know_hosts must have a line for the CA public key in the following format:
    #   @cert-authority * <content of CA public key>
    ssh-keygen -m RFC4716 -t ed25519 -f "$host_key" -N '' -C "root@$hostname" <<< y >/dev/null
    ssh-keygen -Us "${KTHW_SSH_CA_KEY}" -I "${hostname}_ed25519" -n "$hostname" -V -1d:+365d -h "$dir/ssh_host_ed25519_key.pub"

    # add these to cloud-config
    # 1. trusted user CA key
    # 2. host key and certificate (see ssh-keys, https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh)
    yq '
        .write_files += {"path" : "/etc/ssh/trusted-user-ca-keys.pub", "content" : load_str(strenv(KTHW_SSH_CA_KEY))} |
        .write_files += {"path" : "/etc/apt/apt.conf.d/00proxy", "content" : strenv(apt_proxy)} |
        .ssh_keys.ed25519_private = load_str(strenv(host_key)) |
        .ssh_keys.ed25519_certificate = load_str(strenv(host_cert))
    ' configs/debian12.yaml
)

## launch a Debian VM
function kthw-launch () (  # hostname [extra-args]
    set -Eeuox pipefail
    test "$LIBVIRT_DEFAULT_URI"

    hostname=$1

    kthw-cloud-config "$hostname" > "debian12-$hostname.yaml"

    virt-install \
        --name "$hostname" \
        --sysinfo system.serial="ds=nocloud;h=$hostname" \
        --import \
        --autostart \
        --noautoconsole \
        --boot firmware.feature0.enabled=no,firmware.feature0.name=secure-boot \
        --controller type=scsi,model=virtio-scsi \
        --osinfo debian12 \
        --disk size=20,backing_store=/var/lib/libvirt/images/"$(basename "$KTHW_DEBIAN_IMAGE")" \
        --network type=direct,source=eth0,source.mode=bridge,trustGuestRxFilters=yes \
        --cloud-init user-data="debian12-$hostname.yaml" \
        "${@:2}"
    echo
)

## terminate a VM
function kthw-terminate () {
    test "$LIBVIRT_DEFAULT_URI" || return

    virsh destroy "$1"
    virsh undefine --remove-all-storage --nvram "$1"
}

#
# 4. provisioning compute resources
function kthw-launch-all () {
    # launch three VMs: server, node-0, node-1
    kthw-launch server --vcpus 2 --memory 2048
    kthw-launch node-0 --vcpus 1 --memory 1024
    kthw-launch node-1 --vcpus 1 --memory 1024
}

function kthw-terminate-all () {
    kthw-terminate server
    kthw-terminate node-0
    kthw-terminate node-1
}

#
# 5. install etcd on 'server'
function kthw-etcd () (
    set -Eeuo pipefail

    mkdir -p server/usr/local/bin

    tar -xvf downloads/etcd-*-linux-arm64.tar.gz \
        --strip-components 1 -C server/usr/local/bin \
        etcd-*/etcd etcd-*/etcdctl

    install -D -t server/etc/systemd/system units/etcd.service
    install -d -m 0700 server/var/lib/etcd

    rsync -rv --rsync-path 'sudo rsync' --mkpath server/ debian@server:/

    ssh debian@server sudo systemctl enable --now etcd
    ssh debian@server etcdctl member list
)

# create cluster CA
function kthw-ca () {
    # the [req] section from ca.conf is used by default
    # see https://docs.openssl.org/3.5/man1/openssl-req/
    openssl req -x509 -new -newkey ed25519 -noenc \
        -days 3653 -config ca.conf \
        -keyout ca.key -out ca.crt
}

#
# 6. create cluster CA and certificates
function kthw-certs () (
    test -f ca.conf || return

    kthw-ca

    certs=(
        "admin" "node-0" "node-1"
        "kube-proxy" "kube-scheduler"
        "kube-controller-manager"
        "kube-apiserver"
        "service-accounts"
    )

    # ca.conf has two sections for each certificate. e.g. [admin] and [admin_ext]
    # for more details, see https://docs.openssl.org/3.5/man1/openssl-req/
    # and https://docs.openssl.org/3.5/man5/x509v3_config/
    for i in "${certs[@]}"; do
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
            -config ca.conf -section "${i}" -extensions "${i}_ext" -days 3653 \
            -CA ca.crt -CAkey ca.key \
            -keyout "${i}.key" -out "${i}.crt"
    done
)

function set-cluster () {  # kubeconfig
    kubectl config set-cluster kubernetes-the-hard-way \
            --certificate-authority=ca.crt \
            --embed-certs=true \
            --server=https://server:6443 \
            --kubeconfig="$1"
}

function set-credentials () {  # username cert kubeconfig
    kubectl config set-credentials "$1" \
            --client-certificate="$2".crt \
            --client-key="$2".key \
            --embed-certs=true \
            --kubeconfig="$3"
}

function set-context () {  # user kubeconfig
    kubectl config set-context default \
            --cluster=kubernetes-the-hard-way \
            --user="$1" \
            --kubeconfig="$2"
}

function use-context () {  # kubeconfig
    kubectl config use-context default --kubeconfig="$1"
}

# create 'server' kubeconfig files
function kthw-server-kubeconfigs () (
    # kube-proxy, kube-controller-manager, kube-scheduler
    for i in kube-{proxy,controller-manager,scheduler}; do
        set-cluster "${i}.kubeconfig"
        set-credentials "system:${i}" "${i}" "${i}.kubeconfig"
        set-context "system:${i}" "${i}.kubeconfig"
        use-context "${i}.kubeconfig"
    done

    # admin
    set-cluster admin.kubeconfig
    set-credentials admin admin admin.kubeconfig
    set-context admin admin.kubeconfig
    use-context admin.kubeconfig
)

#
# 7. install kube-apiserver, kube-controller-manager, kube-scheduler on 'server'
function kthw-server () {
    install -D -m 0755 -t server/usr/local/bin \
        downloads/kube{-apiserver,-controller-manager,-scheduler}

    # kubernetes configuration
    install -D -t server/etc/kubernetes/config \
        configs/kube-scheduler.yaml

    ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64) \
        envsubst < configs/encryption-config.yaml > encryption-config.yaml

    # kubeconfigs
    kthw-server-kubeconfigs

    install -D -t server/var/lib/kubernetes \
        {ca,kube-apiserver,service-accounts}.{key,crt} \
        kube-controller-manager.kubeconfig kube-scheduler.kubeconfig \
        encryption-config.yaml

    # unit files
    install -t server/etc/systemd/system \
        units/kube-{apiserver,controller-manager,scheduler}.service

    # copy all files to server:/
    rsync -rv --rsync-path 'sudo rsync' --mkpath server/ debian@server:/

    # start services
    ssh debian@server sudo systemctl enable --now kube-apiserver kube-controller-manager kube-scheduler

    # RBAC for kubelet?
    kubectl apply -f configs/kube-apiserver-to-kubelet.yaml
}

function kthw-node () (  # hostname pod-cidr
    set -Eeuox pipefail
    host=$1
    subnet=$2

    # CNI binaries and configuration
    install -D -m 0644 -t "${host}"/etc/cni/net.d configs/99-loopback.conf
    jq --arg subnet "$subnet" \
        '.ipam.ranges[0][0].subnet = $subnet' \
        configs/10-bridge.conf \
        > "${host}"/etc/cni/net.d/10-bridge.conf

    mkdir -p "${host}"/opt/cni/bin
    tar -xvf downloads/cni-plugins-linux-*.tgz -C "${host}"/opt/cni/bin bridge loopback host-local

    # kubelet, kube-proxy, containerd, runc, crictl binaries
    install -D -t "${host}"/usr/local/bin downloads/{kubelet,kube-proxy}
    tar -xvf downloads/containerd-*.tar.gz -C "${host}"/usr/local bin/containerd*

    install -T downloads/runc.arm64 "${host}"/usr/local/bin/runc
    tar xvf downloads/crictl-*.tar.gz -C "${host}"/usr/local/bin crictl

    # kubelet configuration
    install -D -m 0644 -t "${host}"/var/lib/kubelet ca.crt
    cp "$host.crt" "$host/var/lib/kubelet/kubelet.crt"
    cp "$host.key" "$host/var/lib/kubelet/kubelet.key"

    export subnet
    yq e '.podCIDR = env(subnet)' configs/kubelet-config.yaml \
        > "$host"/var/lib/kubelet/kubelet-config.yaml

    # kubelet kubeconfig
    kubeconfig=$host/var/lib/kubelet/kubeconfig
    set-cluster "$kubeconfig"
    set-credentials "system:node:${host}" "$host" "$kubeconfig"
    set-context "system:node:${host}" "$kubeconfig"
    use-context "$kubeconfig"

    # kube-proxy configuration
    kubeproxy=${host}/var/lib/kube-proxy
    mkdir -p "$kubeproxy"
    cp configs/kube-proxy-config.yaml "$kubeproxy"
    cp kube-proxy.kubeconfig "$kubeproxy"/kubeconfig

    # containerd configuration
    install -D -T -m 0644 configs/containerd-config.toml "${host}"/etc/containerd/config.toml

    # unit files
    install -D -t "${host}"/etc/systemd/system \
        units/{kubelet,kube-proxy,containerd}.service

    rsync -rv --rsync-path 'sudo rsync' --mkpath "${host}"/ debian@"${host}":/
    ssh debian@"${host}" sudo systemctl enable --now kubelet kube-proxy containerd
)


# resolve hostname to IP address
function kthw-node-ip () (  # hostname
    set -Eeuo pipefail

    host=$1
    ip=$(dig -4 +short "$host")

    # fallback for DNS
    if [[ -z "$ip" ]]; then
        ip=$(virsh domifaddr "$host" --source agent | \
            awk '/52:54/ {gsub("/[[:digit:]]+", "", $4); print $4}')
    fi

    echo "$ip"
)

## set up pod routes
## FIXME: make this work for more than two pod CIDRs
function kthw-routes () (  # pod-cidr-0 pod-cidr-1
    set -Eeuo pipefail

    node0_ip=$(kthw-node-ip node-0)
    node1_ip=$(kthw-node-ip node-1)

    if [[ -z "$node0_ip" || -z "$node1_ip" ]]; then
        echo "Error: Failed to retrieve node IPs."
        exit 1
    fi

    set -Eeuox pipefail
    # shellcheck disable=SC2029
    {
        ssh debian@server sudo ip route add "$2" via "$node1_ip"
        ssh debian@server sudo ip route add "$1" via "$node0_ip"

        ssh debian@node-0 sudo ip route add "$2" via "$node1_ip"
        ssh debian@node-1 sudo ip route add "$1" via "$node0_ip"
    }
)

#
# 8. install kubelet, kube-proxy, containerd, runc, CNI plugins and pod routes on worker nodes (node-0, node-1)
function kthw-nodes () {
    kthw-node node-0 "$KTHW_POD_CIDR0"
    kthw-node node-1 "$KTHW_POD_CIDR1"

    kthw-routes "$KTHW_POD_CIDR0" "$KTHW_POD_CIDR1"
}
