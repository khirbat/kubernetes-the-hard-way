# Kubernetes The Hard Way (3 VMs on a Raspberry Pi 5)

`kthw.sh` is a collection of [`bash`](https://www.man7.org/linux/man-pages/man1/bash.1.html) functions for setting up a basic [Kubernetes](https://kubernetes.io) cluster with 3 nodes for personal experimentation and learning on a [Raspberry Pi 5](https://www.raspberrypi.org/products/raspberry-pi-5/).

The three nodes are `server`, `node-0`, and `node-1`.
- `server` runs [`etcd`](https://etcd.io), [`kube-apiserver`](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/), [`kube-controller-manager`](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/), [`kube-scheduler`](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/). It is also configured to run [`kubectl`](https://kubernetes.io/docs/reference/kubectl/kubectl/).
- `node-0` and `node-1` run [`kubelet`](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/), [`kube-proxy`](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/), [`containerd`](https://containerd.io/), and [`runc`](https://github.com/opencontainers/runc)

## License

This repository reuses files from the original [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) by Kelsey Hightower. It follows the license of the original Kubernetes the Hard Way: [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).

## Prerequisites
- **Raspberry Pi 5**
  - 8GB RAM
  - Ethernet connection
  - SSH public key auth and `sudo` without password for user `pi`

- **Functioning DNS** that resolves the names `server`, `node-0`, and `node-1`.

- **Local Linux system (or local macOS system** with [Homebrew](https://brew.sh)) and:
  - [`openssl`](https://www.openssl.org/), [`parallel`](https://www.gnu.org/software/parallel/), [`jq`](https://stedolan.github.io/jq/), [`yq`](https://mikefarah.gitbook.io/yq/), [`virt-install`](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst) installed
  - SSH agent (e.g. [Secretive on macOS](https://github.com/maxgoedjen/secretive)) with CA key
  - On macOS, if `bash` is not the default shell, run `bash -l` in any Terminal window as needed.  Or refer to this Apple support article on [default shells](https://support.apple.com/en-us/102360) for more information and instructions.

- Create a **configuration file**, `config.sh` to specify:
  - `KTHW_PI_HOST` hostname or IP of the Raspberry Pi system
  - `KTHW_SSH_CA_KEY` public key of SSH CA signing key held in SSH agent
  - `KTHW_DEBIAN_IMAGE` URL of [Debian Cloud image](https://cloud.debian.org/images/cloud/)
  - `POD_CIDRn` pod CIDRs

  ```bash
  $ cat config.sh
  KTHW_PI_HOST=5a
  KTHW_SSH_CA_KEY=$HOME/.ssh/ca.pub
  KTHW_DEBIAN_IMAGE="https://cloud.debian.org/images/cloud/bookworm/20240717-1811/debian-12-genericcloud-arm64-20240717-1811.qcow2"
  KTHW_POD_CIDR0=10.200.0.0/24
  KTHW_POD_CIDR1=10.200.1.0/24
  ```

## Instructions

The commands in this section will run on the local Linux or macOS system to set up the VMs and create and configure the cluster over `ssh`.

Source the `bash` script `kthw.sh`. This allows calling its functions directly and incrementally.

```bash
source kthw.sh
```

Each function in `kthw.sh` marked with a numbered comment (e.g. `# 5. install etcd on 'server'`) represents a specific step in the setup process. These functions are intended to be executed one at a time to progressively build up the Kubernetes cluster. This makes it easy to understand and troubleshoot each phase of the setup.

```bash
# 1. local environment setup
kthw-setup

# 2. Raspberry Pi OS setup (install packages and set up libvirt)
kthw-rpi-setup

# 3. download packages listed in downloads.txt
kthw-dl

# 4. launch Debian VMs (server, node-0, node-1)
kthw-launch-all

# 5. install etcd on 'server'
kthw-etcd

# 6. create cluster CA
kthw-ca

# 7. create cluster certificates
kthw-certs

# 8. install kube-apiserver, kube-controller-manager, kube-scheduler, kubectl on 'server'
kthw-server

# 9. install kublet, kubeproxy, containerd, runc, CNI plugins and pod routes on worker nodes (node-0, node-1)
kthw-nodes
```
