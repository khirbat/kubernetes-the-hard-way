# Kubernetes The Hard Way (3 VMs on a Raspberry Pi 5)

[kthw.sh](./kthw.sh) is a collection of [`bash`](https://www.man7.org/linux/man-pages/man1/bash.1.html) [functions](https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html) for setting up a basic, experimental [Kubernetes](https://kubernetes.io) [cluster](https://kubernetes.io/docs/reference/glossary/?all=true#term-cluster) on a [Raspberry Pi 5](https://www.raspberrypi.org/products/raspberry-pi-5/).

The Kubernetes cluster for this guide consists of three Debian VMs: `server`, `node-0`, and `node-1`. Each VM runs a specific set of [Kubernetes components](https://kubernetes.io/docs/concepts/overview/components/):
- `server` runs
  - [etcd](https://etcd.io)
  - [kube-apiserver](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
  - [kube-controller-manager](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
  - [kube-scheduler](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/)

- `node-0` and `node-1` run
  - [kubelet](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/)
  - [kube-proxy](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/)
  - [containerd](https://containerd.io/)
  - [runc](https://github.com/opencontainers/runc)
  - [CNI](https://github.com/containernetworking/plugins#main-interface-creating) plugins (`bridge` and `loopback`)

`node-0` and `node-1` are Kubernetes worker [Nodes](https://kubernetes.io/docs/reference/glossary/?all=true#term-node) that run [Pods](https://kubernetes.io/docs/reference/glossary/?all=true#term-pod).

## License

This repository reuses content from [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) by Kelsey Hightower and is licensed under the same [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).

## Prerequisites
- **Local Linux system** (or **local macOS system** with [Homebrew](https://brew.sh))

- **`bash` as the default shell** on your local system

  On macOS, if `bash` is not the default shell, run `bash -l` in any Terminal window as needed. You can also refer to the Apple support article on [default shells](https://support.apple.com/en-us/102360) for more information on changing the default shell.

- **Raspberry Pi 5 (remote, headless)**
  - 8 GB RAM
  - Ethernet connection
  - Accessible from the local system using SSH public key authentication
  - `sudo` without password for user `pi`

- **Functioning DNS** that resolves the names `server`, `node-0`, `node-1`
  ```console
  $ dig +noall +answer node-0
  node-0.			0	IN	A	192.168.1.215
  ```

## Instructions

### Set up SSH on local system

#### Verify SSH access to the Raspberry Pi from your local system

```console
$ ssh pi@5a  # replace 5a with the hostname or IPv4 address of your Raspberry Pi
pi@5a:~ $ sudo -i  # also verify that sudo works without a password
root@5a:~#
```

#### Set up SSH CA for creating SSH certificates

An SSH CA key will be used to create SSH user and host certificates. For more details, see the [OpenSSH documentation on certificates](https://manpages.debian.org/bookworm/openssh-client/ssh-keygen.1.en.html#CERTIFICATES).

For each newly created VM, a [HostKey](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html#HostKey) and [HostCertificate](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html#HostCertificate) are generated and inserted into the VM by [cloud-init](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh). This allows the first SSH connection to that VM to be trusted automatically without encountering the usual SSH [TOFU](https://en.wikipedia.org/wiki/Trust_on_first_use) message and prompt like this:

```console
$ ssh terminal.shop
The authenticity of host 'terminal.shop (2606:4700:70:0:c902:90f7:265f:4f58)' can't be established.
ED25519 key fingerprint is SHA256:TMZnO7N8mmR/Pap3urU2P4uBNuhxuWtDUak0g9gyZ8s.
This key is not known by any other names.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

The SSH CA is also used to create SSH user certificates for logging into the VMs. `cloud-init` will set up [TrustedUserCAKeys](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html#TrustedUserCAKeys) on each VM during the first boot. This is an alternative to adding a public key to `~/.ssh/authorized_keys`.

There are two ways to set up the SSH CA key and SSH user certificates. The first works for both Linux and macOS. The second is for macOS systems using [Secretive](https://github.com/maxgoedjen/secretive). Secretive stores and manages SSH keys in the Secure Enclave on Macs and also provides its own SSH agent.

##### Generic SSH CA setup using [ssh-agent(1)](https://manpages.debian.org/bookworm/openssh-client/ssh-agent.1.en.html) on Linux or macOS

- Create a new SSH key (`~/.ssh/ca`) that serves as the SSH CA signing key by running the following command on your local system:

  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/ca -C "SSH CA XYZ" -N ""
  ```

- Add the CA public key to `~/.ssh/known_hosts` on your local system:

  ```bash
  echo "@cert-authority * $(cat ~/.ssh/ca.pub)" >> ~/.ssh/known_hosts
  ```

- Add the CA key to the SSH agent on your local system to allow signing certificates using [ssh-keygen -U](https://manpages.debian.org/bookworm/openssh-client/ssh-keygen.1.en.html#U):

  ```bash
  ssh-add ~/.ssh/ca
  ```

  If an SSH agent is not running, start it with the following command and retry the `ssh-add` command:

  ```bash
  eval "$(ssh-agent -s)"
  ```

- To create an SSH user certificate from an existing ed25519 key, run the command:

  ```bash
  ssh-keygen -Us ~/.ssh/ca.pub -I "$(hostname -s)-$(date -u +"%Y%m%d%H%M%S")" -n debian,alpine -V -1d:+365d ~/.ssh/id_ed25519.pub
  ```

  ```console
  Signed user key /home/debian/.ssh/id_ed25519-cert.pub: id "deb1-20250613173629" serial 0 for debian valid from 2025-06-12T17:36:29 to 2026-06-13T17:36:29
  ```

- (optional) To view the details of an SSH certificate, run:

  ```console
  $ ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub
  ```

##### SSH CA setup using [Secretive](https://github.com/maxgoedjen/secretive) on macOS

- Install Secretive using [Homebrew](https://brew.sh):

  ```bash
  brew install secretive
  ```

- Launch Secretive.app and create a new SSH key by clicking on the "+" button. Use the name "SSH CA" to identify the key as your SSH CA signing key.

- Create a second SSH key. This key will be used to create an SSH user certificate for logging into the VMs.

- Locate the SSH public key files:

  ```bash
  cd "$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/"
  ls -1
  ```

  You should see two files, one for the SSH CA key and another one for the SSH user key.

  ```console
  65dc48185c6cb16015237da874f9a1cf.pub
  e76a9c3256555dc1ff91584f49f0021f.pub
  ```

- Sign the SSH user key to create the user certificate:

  ```console
  SSH_AUTH_SOCK=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh \
      ssh-keygen -Us 65dc48185c6cb16015237da874f9a1cf.pub \
      -I "$(hostname -s)-$(date -u +"%Y%m%d%H%M%S")" -n debian,alpine -V -1d:+365d \
      e76a9c3256555dc1ff91584f49f0021f.pub
  ```

- (optional) List details of keys and certificates held in the Secretive SSH agent:

  ```bash
  SSH_AUTH_SOCK=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh \
      ssh-add -l
  ```

  ```console
  256 SHA256:eW/djamoJCIh4mMcEhpqBmdggYN5bb3Hw4Bbvb4T+fg ecdsa-sha2-nistp256 (ECDSA)
  256 SHA256:3q2c1f/kaUk6xCoixk/jRKSt+TydOE13wu8jnwT6xmA ecdsa-sha2-nistp256 (ECDSA)
  256 SHA256:3q2c1f/kaUk6xCoixk/jRKSt+TydOE13wu8jnwT6xmA e76a9c3256555dc1ff91584f49f0021f.pub (ECDSA-CERT)
  ```

### Clone this Git repository

Clone this repository to your local system and change into the directory:

```bash
git clone https://github.com/me/kubernetes-the-hard-way.git
cd kubernetes-the-hard-way
```

> Note: `kubernetes-the-hard-way/` on the local system will be the working directory for the rest of the text.

### Create configuration file for `kthw.sh`

`kthw.sh` uses these environment variables. The variables are defined in the file [config.sh](./config.sh) and sourced by `kthw.sh`.

- `KTHW_PI_HOST` hostname or IPv4 address of the Raspberry Pi system
- `KTHW_SSH_CA_KEY` path to the SSH CA public key file (e.g. `~/.ssh/ca.pub` or `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/65dc48185c6cb16015237da874f9a1cf.pub`)
- `KTHW_DEBIAN_IMAGE` URL of `genericcloud-arm64` [Debian Cloud image](https://cloud.debian.org/images/cloud/)
- `KTHW_POD_CIDRn` pod CIDRs
- (optional) `KTHW_APT_CACHER_NG` URL of [apt-cacher-ng(8)](https://manpages.debian.org/bookworm/apt-cacher-ng/apt-cacher-ng.8.en.html) server

Create the file `config.sh` in the working directory (`kubernetes-the-hard-way/`) with the following content. Replace the values of `KTHW_PI_HOST` and `KTHW_SSH_CA_KEY` with values appropriate for your setup.

```bash
$ cat >config.sh <<EOF
KTHW_PI_HOST=5a
KTHW_SSH_CA_KEY=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/7c66b4c7decda51b23caf600d9d379f3.pub  # or $HOME/.ssh/ca.pub
KTHW_DEBIAN_IMAGE="https://cloud.debian.org/images/cloud/trixie/20251117-2299/debian-13-genericcloud-arm64-20251117-2299.qcow2"
KTHW_POD_CIDR0=10.200.0.0/24
KTHW_POD_CIDR1=10.200.1.0/24
EOF
```

### Source `kthw.sh`

Source the `bash` script `kthw.sh`. This allows you to call its functions directly and incrementally.

```bash
source kthw.sh
```

Each function in `kthw.sh` that is marked with a numbered comment represents a specific step in the process. e.g.

```bash
#
# 5. install etcd on 'server'
function kthw-etcd () (
...
```

These functions are intended to be executed one at a time to progressively build the Kubernetes cluster, making it easier to understand and troubleshoot each step.

> Note: All the `bash` functions in `kthw.sh` must be executed from the same directory where `kthw.sh` is located, i.e. the working directory `kubernetes-the-hard-way/`.

### 1. Set up the local system

`kthw.sh` needs these tools on the local system: [OpenSSL](https://www.openssl.org/), [GNU Parallel](https://www.gnu.org/software/parallel/), [jq](https://stedolan.github.io/jq/), [yq](https://mikefarah.gitbook.io/yq/), [virsh](https://www.libvirt.org/manpages/virsh.html), [virt-install](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst).

It also relies on these environment variables: `PATH`, `LIBVIRT_DEFAULT_URI`, `SSH_AUTH_SOCK`, `KUBECONFIG`.

Run the `bash` function `kthw-setup` to install the packages and set the environment variables.

```bash
kthw-setup
```

### 2. Set up the Raspberry Pi

The next step is to prepare the Raspberry Pi for running the Debian VMs. This involves installing `libvirt` and creating a `libvirt` volume from a Debian Cloud image (e.g. `debian-13-genericcloud-arm64-20251117-2299.qcow2`, supplied via `$KTHW_DEBIAN_IMAGE`). The Debian Cloud image volume will be used later when launching the VMs.

Run the `bash` function `kthw-rpi-setup` to set up `libvirt` on the Raspberry Pi:

```bash
kthw-rpi-setup
```

To view the details on the Debian Cloud image volume:

```bash
virsh vol-info --pool default "$(basename "$KTHW_DEBIAN_IMAGE")"
```

```console
Name:           debian-13-genericcloud-arm64-20251117-2299.qcow2
Type:           file
Capacity:       3.00 GiB
Allocation:     3.00 GiB
```

The `virsh` command runs on the local system and uses the environment variable `LIBVIRT_DEFAULT_URI` to connect to the `libvirt` daemon on the Raspberry Pi.

### 3. Download binaries listed in [downloads.txt](./downloads.txt)

Run the `bash` function `kthw-dl` to download the Kubernetes components to `downloads/`:

```bash
kthw-dl
```

The total size is approximately 500 MB.

```console
$ ls -oh downloads/
total 465M
-rw-r--r-- 1 pi 49M Sep  1 08:29 cni-plugins-linux-arm64-v1.8.0.tgz
-rw-r--r-- 1 pi 31M Nov  5 17:34 containerd-2.2.0-linux-arm64.tar.gz
-rw-r--r-- 1 pi 18M Aug 21 00:58 crictl-v1.34.0-linux-arm64.tar.gz
-rw-r--r-- 1 pi 22M Nov 11 21:18 etcd-v3.6.6-linux-arm64.tar.gz
-rw-r--r-- 1 pi 77M Nov 12 01:24 kube-apiserver
-rw-r--r-- 1 pi 65M Nov 12 01:24 kube-controller-manager
-rw-r--r-- 1 pi 41M Nov 12 01:24 kube-proxy
-rw-r--r-- 1 pi 45M Nov 12 01:24 kube-scheduler
-rw-r--r-- 1 pi 56M Nov 12 01:24 kubectl
-rw-r--r-- 1 pi 54M Nov 12 01:24 kubelet
-rw-r--r-- 1 pi 11M Nov  5 01:15 runc.arm64
```

### 4. Provision compute resources

Everything needed for creating and setting up the Debian VMs on the Raspberry Pi is now in place. This section explains how the VMs are created and configured. If needed, you can [destroy the VMs](#10-cleanup) and start over from this step at any time.

Run the `bash` function `kthw-launch-all` to create these VMs:

| Hostname | Description            | CPU |  RAM    | Storage |
|----------|------------------------|-----|---------|---------|
| server   | Kubernetes server      |  2  | 2048 MB |  20 GB  |
| node-0   | Kubernetes worker node |  1  | 1024 MB |  20 GB  |
| node-1   | Kubernetes worker node |  1  | 1024 MB |  20 GB  |

```bash
kthw-launch-all
```

`kthw-launch-all` uses [virt-install](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst) to create the VMs. The 20 GB disk for each VM is created from the Debian Cloud image volume. Each VM's network interface is directly attached to the physical `eth0` interface on the Raspberry Pi. The VMs appear on the same local network as the Raspberry Pi and obtain IPv4 addresses via DHCP from the main network. The VMs can communicate with other hosts on the same network directly without NAT or port forwarding.

`kthw-launch-all` also generates an SSH host key and certificate for each VM. The [SSH configuration](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh) for each VM is combined with `configs/debian13.yaml` and inserted into each VM using `virt-install`'s [--cloud-init](https://manpages.debian.org/bookworm/virtinst/virt-install.1.en.html#--cloud-init) option.

Verify that the VMs are running, using the `virsh list` command:

```bash
virsh list
```
```console
 Id   Name     State
------------------------
 7    server   running
 8    node-0   running
 9    node-1   running
```

Verify that the VMs are accessible using `ssh`:

```console
kubernetes-the-hard-way $ ssh debian@server uname -a
Linux server 6.12.57+deb13-cloud-arm64 #1 SMP Debian 6.12.57-1 (2025-11-05) aarch64 GNU/Linux

kubernetes-the-hard-way $ ssh debian@node-1 uname -a
Linux node-1 6.12.57+deb13-cloud-arm64 #1 SMP Debian 6.12.57-1 (2025-11-05) aarch64 GNU/Linux
```

### 5. Install etcd on `server`

Kubernetes components are stateless and store cluster state in [etcd](https://etcd.io), a distributed key-value store. This guide sets up a single-member `etcd` cluster on `server`.

Run the `bash` function `kthw-etcd` to copy the `etcd` binaries to `server` and start `etcd`:

```bash
kthw-etcd
```

### 6. Create cluster CA and certificates

Run the `bash` function `kthw-certs` to create these certificates (and keys):

- `ca.crt` - root CA certificate for the Kubernetes cluster, used to sign all other certificates
- `admin.crt` - client certificate for the cluster administrator to access `kube-apiserver`
- `kube-apiserver.crt` - `kube-apiserver` server certificate
- `service-accounts.crt` - certificate for signing Kubernetes [service account](https://kubernetes.io/docs/concepts/security/service-accounts/) tokens
- `kube-controller-manager.crt`, `kube-scheduler.crt` - client certificates to authenticate to `kube-apiserver`
- `node-0.crt`, `node-1.crt` - client certificates for `kubelet` on each worker node to authenticate to `kube-apiserver`

```bash
kthw-certs
```

For details on Kubernetes certificates and the cluster PKI, see [PKI certificates and requirements](https://kubernetes.io/docs/setup/best-practices/certificates/).

### 7. Install kube-apiserver, kube-controller-manager, kube-scheduler on `server`

Run the `bash` function `kthw-server` to:

- Copy binaries and configuration files
- Start the `kube-apiserver`, `kube-controller-manager`, and `kube-scheduler` services

```bash
kthw-server
```

### 8. Install kubelet, kube-proxy, containerd, runc, CNI plugins, and pod routes on `node-0` and `node-1`

Run the `bash` function `kthw-nodes` to:

- Copy binaries and configuration files
- Start the `kubelet`, `kube-proxy`, and `containerd` services

```bash
kthw-nodes
```

### 9. Smoke test

[smoke.sh](./smoke.sh) contains `bash` functions for testing basic Kubernetes functionality. Review the functions in `smoke.sh` and run them one at a time to understand what each test does.

```bash
source smoke.sh
```

### 10. Cleanup

- Destroy the three Debian VMs in the cluster:

  ```bash
  source kthw.sh
  kthw-terminate-all
  ```

- Review the list of files that will be deleted and save any files you wish to keep:

  ```bash
  git clean -fxd -n  # dry-run to review files that will be deleted
  ```

- Delete all files unknown to `git`, including ignored files:

  ```bash
  git clean -fxd
  ```

- Delete all files unknown to `git`, but keep the downloads and `admin.kubeconfig`:

  ```bash
  git clean -fxd -e downloads/ -e admin.kubeconfig
  ```
