# Kubernetes The Hard Way (3 VMs on a Raspberry Pi 5)

`kthw.sh` is a collection of [`bash`](https://www.man7.org/linux/man-pages/man1/bash.1.html) functions for setting up a basic, experimental [Kubernetes](https://kubernetes.io) [cluster](https://kubernetes.io/docs/reference/glossary/?all=true#term-cluster) on a [Raspberry Pi 5](https://www.raspberrypi.org/products/raspberry-pi-5/).

The Kubernetes cluster consists of three Debian VMs: `server`, `node-0`, and `node-1`. The three VMs run the following [Kubernetes components](https://kubernetes.io/docs/concepts/overview/components/)
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
- **Local Linux system (or local macOS system** with [Homebrew](https://brew.sh))

- **`bash` as the default shell** on your local system
  On macOS, if `bash` is not the default shell, run `bash -l` in any Terminal window as needed. You can also refer to the Apple support article on [default shells](https://support.apple.com/en-us/102360) for more information on changing the default shell.

- **Raspberry Pi 5 (remote, headless)**
  - 8GB RAM
  - Ethernet connection
  - Accessible from the local system using SSH public key authentication
  - `sudo` without password for user `pi`

- **Functioning DNS** that resolves the names `server`, `node-0`, `node-1`
  ```console
  $ dig +short node-0
  192.168.1.215
  ```

## Instructions

### Set up SSH on local system

- Verify Raspberry Pi SSH access from local system

  ```console
  $ ssh pi@5a  # replace 5a with the hostname or IP of your Raspberry Pi
  pi@5a:~ $ sudo -i  # also verify that sudo works without a password
  root@5a:~#
  ```

- Set up SSH CA for creating SSH certificates

  An SSH CA key will be used to create SSH user and host certificates. For more details, see the [OpenSSH documentation on certificates](https://manpages.debian.org/bookworm/openssh-client/ssh-keygen.1.en.html#CERTIFICATES).

  For each newly launched VM, a [HostKey](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html#HostKey) and [HostCertificate](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html#HostCertificate) are generated and inserted into the VM by [Cloud-init](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh). This allows the very first SSH connection to the VM to be trusted automatically without encountering the usual SSH [TOFU](https://en.wikipedia.org/wiki/Trust_on_first_use) message and prompt (e.g. `The authenticity of host 'terminal.shop (2606:4700:70:0:c902:90f7:265f:4f58)' can't be established. ...`). It also makes it easier to terminate and recreate a VM without having to manually remove old host keys from `~/.ssh/known_hosts` and encountering the SSH TOFU prompt again.

  The SSH CA is also used to create SSH user certificates for logging into the VMs. `Cloud-init` will set up [TrustedUserCAKeys](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html#TrustedUserCAKeys) on each VM during the first boot. This is an alternative to the traditional SSH public key authentication method, where the public key is added to the `~/.ssh/authorized_keys` file on each VM for specific users.

  There are two sets of instructions for setting up the SSH CA key and SSH user certificates. The first set of instructions is generic and works for both Linux and macOS systems. The second set of instructions is for macOS systems using [Secretive](https://github.com/maxgoedjen/secretive). Secretive stores and manages SSH keys in the Secure Enclave on Macs and also provides its own SSH agent.

#### 1. Generic SSH CA setup using [ssh-agent(1)](https://manpages.debian.org/bookworm/openssh-client/ssh-agent.1.en.html) on Linux or macOS
    - Create a new SSH key (`~/.ssh/ca`) that serves as the SSH CA signing key by running the following command on your local system:
      ```bash
      ssh-keygen -t ed25519 -f ~/.ssh/ca -C "SSH CA XYZ" -N ""
      ```
    - Add CA public key to `~/.ssh/known_hosts` on your local system:
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
    - To create an SSH user certificate from a preexisting ed25519 key, run the command:
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

#### 2. SSH CA setup using [Secretive](https://github.com/maxgoedjen/secretive) on macOS
    - Install Secretive using [Homebrew](https://brew.sh):
      ```bash
      brew install secretive
      ```
    - Launch Secretive.app and create a new SSH key by clicking on the "+" button. Use the name "SSH CA" to identify the key as your SSH CA signing key.
    - Create a second SSH key. This key will be used to create an SSH user certificate for logging into the VMs.
    - Locate the SSH public key files:
      ```bash
      cd $HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/
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
        ssh-keygen -Us 65dc48185c6cb16015237da874f9a1cf.pub -I "$(hostname -s)-$(date -u +"%Y%m%d%H%M%S")" -n debian,alpine -V -1d:+365d e76a9c3256555dc1ff91584f49f0021f.pub
      ```
    - (optional) List details of keys and certificates held in the Secretive SSH agent:
      ```bash
      SSH_AUTH_SOCK=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh ssh-add -l
      ```

      ```console
      256 SHA256:eW/djamoJCIh4mMcEhpqBmdggYN5bb3Hw4Bbvb4T+fg ecdsa-sha2-nistp256 (ECDSA)
      256 SHA256:3q2c1f/kaUk6xCoixk/jRKSt+TydOE13wu8jnwT6xmA ecdsa-sha2-nistp256 (ECDSA)
      256 SHA256:3q2c1f/kaUk6xCoixk/jRKSt+TydOE13wu8jnwT6xmA e76a9c3256555dc1ff91584f49f0021f.pub (ECDSA-CERT)
      ```

### Clone this Git repository

Clone this repository to your local macOS or Linux system and change into the cloned directory.

  ```bash
  git clone https://github.com/me/kubernetes-the-hard-way.git
  cd kubernetes-the-hard-way
  ```

> Note: `kubernetes-the-hard-way/` on the local system will be the working directory for the rest of the text.

### Create configuration file for `kthw.sh`

`kthw.sh` makes use of the following environment variables. The variables are defined in the file `config.sh` and sourced by `kthw.sh`

  - `KTHW_PI_HOST` hostname or IP of the Raspberry Pi system
  - `KTHW_SSH_CA_KEY` public key of SSH CA signing key held in SSH agent (e.g. `~/.ssh/ca.pub` or `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/65dc48185c6cb16015237da874f9a1cf.pub`)
  - `KTHW_DEBIAN_IMAGE` URL of `genericcloud-arm64` [Debian Cloud image](https://cloud.debian.org/images/cloud/)
  - `KTHW_POD_CIDRn` pod CIDRs
  - (optional) `KTHW_APT_CACHER_NG` URL of `apt-cacher-ng(8)` server

Create the file `config.sh` in the working directory (`kubernetes-the-hard-way/`) with the following content. Replace the values of KTHW_PI_HOST and KTHW_SSH_CA_KEY with the appropriate values for your setup.

  ```bash
  $ cat >config.sh <<EOF
  KTHW_PI_HOST=5a
  KTHW_SSH_CA_KEY=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/7c66b4c7decda51b23caf600d9d379f3.pub  # or $HOME/.ssh/ca.pub
  KTHW_DEBIAN_IMAGE="https://cloud.debian.org/images/cloud/bookworm/20250519-2117/debian-12-genericcloud-arm64-20250519-2117.qcow2"
  KTHW_POD_CIDR0=10.200.0.0/24
  KTHW_POD_CIDR1=10.200.1.0/24
  EOF
  ```

### Source `kthw.sh`

Source the `bash` script `kthw.sh`. This allows you to call its functions directly and incrementally.

```bash
source kthw.sh
```

Each function in `kthw.sh` marked with a numbered comment which represents a specific step in the process. e.g.

```bash
#
# 5. install etcd on 'server'
function kthw-etcd () (
...
```

These functions are intended to be executed one at a time to progressively build up the Kubernetes cluster. This makes it easy to understand and troubleshoot each phase of the setup.

> Note: All the `bash` functions in `kthw.sh` must be executed from the same directory where `kthw.sh` is located, i.e. the working directory `kubernetes-the-hard-way/`.

### 1. Set up the local system

`kthw.sh` needs the following utilities to be installed on the local system: [OpenSSL](https://www.openssl.org/), [GNU Parallel](https://www.gnu.org/software/parallel/), [jq](https://stedolan.github.io/jq/), [yq](https://mikefarah.gitbook.io/yq/), [virsh](https://www.libvirt.org/manpages/virsh.html), [virt-install](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst). `kthw.sh` also needs the following environment variables to be set: `PATH`, `LIBVIRT_DEFAULT_URI`, `SSH_AUTH_SOCK`, `KUBECONFIG`

Run the `bash` function `kthw-setup` to install the packages and set the environment variables.

```bash
kthw-setup
```

### 2. Set up the Raspberry Pi

The next step is to prepare the Raspberry Pi for running the Debian VMs. This involves installing `libvirt` and creating a `libvirt` volume from a Debian Cloud image  (e.g. `debian-12-genericcloud-arm64-20250519-2117.qcow2`, supplied via `$KTHW_DEBIAN_IMAGE`). The Debian Cloud image volume will be used later when launching the VMs.

Run the `bash` function `kthw-rpi-setup` to set up `libvirt` on the Raspberry Pi

```bash
kthw-rpi-setup
```

To verify the Debian Cloud image volume, run the following command:
```bash
virsh vol-info --pool default $(basename $KTHW_DEBIAN_IMAGE)
```

```console
Name:           debian-12-genericcloud-arm64-20250519-2117.qcow2
Type:           file
Capacity:       3.00 GiB
Allocation:     3.00 GiB
```

The `virsh` command runs on the local system and uses the environment variable `LIBVIRT_DEFAULT_URI` to connect to the `libvirt` daemon on the Raspberry Pi.

### 3. Download binaries listed in downloads.txt

The function `kthw-dl` will use `curl` to download the binaries listed in `downloads.txt` to the directory `kubernetes-the-hard-way/downloads/` on the local system.

Run the `bash` function `kthw-dl` to download the Kubernetes components.

```bash
kthw-dl
```

The total size of all the binaries is approximately 500 MB. Use the `ls` command to list the downloaded files.

```bash
ls -oh downloads/
```

```console
total 559M
-rw-r--r--. 1 pi 50M Apr 25 12:58 cni-plugins-linux-arm64-v1.7.1.tgz
-rw-r--r--. 1 pi 30M May 20 18:01 containerd-2.1.1-linux-arm64.tar.gz
-rw-r--r--. 1 pi 19M Apr 22 07:51 crictl-v1.33.0-linux-arm64.tar.gz
-rw-r--r--. 1 pi 21M May 15 19:39 etcd-v3.6.0-linux-arm64.tar.gz
-rw-r--r--. 1 pi 89M May 15 17:47 kube-apiserver
-rw-r--r--. 1 pi 83M May 15 17:47 kube-controller-manager
-rw-r--r--. 1 pi 56M May 15 17:47 kubectl
-rw-r--r--. 1 pi 75M May 15 17:47 kubelet
-rw-r--r--. 1 pi 65M May 15 17:47 kube-proxy
-rw-r--r--. 1 pi 64M May 15 17:47 kube-scheduler
-rw-r--r--. 1 pi 11M Apr 29 04:43 runc.arm64
```

### 4. Provision Compute Resources

Everything needed for creating and setting up the Debian VMs on the Raspberry Pi is now in place. This section explains the details of how the VMs are created and configured.

Run the `bash` function `kthw-launch-all` to create the following VMs.

| Hostname | Description            | CPU |  RAM    | Storage |
|----------|------------------------|-----|---------|---------|
| server   | Kubernetes server      |  2  | 2048 MB |  20 GB  |
| node-0   | Kubernetes worker node |  1  | 1024 MB |  20 GB  |
| node-1   | Kubernetes worker node |  1  | 1024 MB |  20 GB  |

```bash
kthw-launch-all
```

`kthw-launch-all` uses the `virt-install` utility to create the VMs. The 20 GB disk for each VM is created from the Debian Cloud image volume. Each VM's network interface is directly attached to the physical `eth0` interface on the Raspberry Pi. The VMs appear on the same local network as the Raspberry Pi and can obtain their own IP addresses via DHCP on the local network. The VMs can communicate with other hosts on the same network directly without NAT or port forwarding.

`kthw-launch-all` also generates an SSH host key and certificate for each VM. The [SSH configuration](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh) for each VM is combined with `configs/debian12.yaml` and inserted into each VM using `virt-install`'s [--cloud-init](https://manpages.debian.org/bookworm/virtinst/virt-install.1.en.html#--cloud-init) option.

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
Linux server 6.1.0-35-cloud-arm64 #1 SMP Debian 6.1.137-1 (2025-05-07) aarch64 GNU/Linux

kubernetes-the-hard-way $ ssh debian@node-1 uname -a
Linux node-1 6.1.0-35-cloud-arm64 #1 SMP Debian 6.1.137-1 (2025-05-07) aarch64 GNU/Linux
```

### 5. Install etcd on 'server'

Kubernetes components are stateless and store cluster state in [etcd](https://etcd.io), a distributed key-value store. This guide sets up a single-node `etcd` cluster on `server` VM.

Run the `bash` function `kthw-etcd` to copy the `etcd` binaries to `server` and start `etcd`.

```bash
kthw-etcd
```

### 6. Create cluster CA and certificates

Run the `bash` function `kthw-certs` to create the following certificates (and keys):

- `ca.crt` - the root CA certificate for the Kubernetes cluster used to sign all other certificates
- `admin.crt` - client certificate for the `admin` user, used to access the Kubernetes API server
- `kube-apiserver.crt` - `kube-apiserver` server certificate
- `service-accounts.crt` - certificate for signing k8s service account tokens
- `kube-controller-manager.crt`, `kube-scheduler.crt` - client certificates to authenticate to the `kube-apiserver`
- `node-0.crt`, `node-1.crt` - client certificates for the `kubelet` on each worker node to authenticate to the `kube-apiserver`

```bash
kthw-certs
```

### 7. Install kube-apiserver, kube-controller-manager, kube-scheduler on 'server'

Run the `bash` function `kthw-server` to
- copy binaries and configuration files
- start the `kube-apiserver`, `kube-controller-manager`, and `kube-scheduler` services.

```bash
kthw-server
```

### 8. Install kubelet, kube-proxy, containerd, runc, CNI plugins and pod routes `node-0` and `node-1` (worker nodes)

Run the `bash` function `kthw-nodes` to
- copy binaries and configuration files
- start the `kubelet`, `kube-proxy` and `containerd` services

```bash
kthw-nodes
```

### Smoke Test

`smoke.sh` contains a set of `bash` functions for testing basic Kubernetes functionality. Review the functions in `smoke.sh` and run them one at a time to understand what each test does.

```bash
source smoke.sh
```

### Cleanup

- Destroy the three Debian VMs in the cluster

```bash
source kthw.sh
kthw-terminate-all
```

- Review the list of files that will be deleted from the local system in the final step and preserve any files you want to keep outside of the `kubernetes-the-hard-way/` directory.

```bash
git clean -fxd -n  # dry-run to review list of files that will be deleted
```

- Delete all files unknown to `git`, including ignored files.

```bash
git clean -fxd
```
