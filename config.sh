#!/bin/bash
# shellcheck disable=SC2034

if ! (return 0 2>/dev/null); then
    exit 2
fi

KTHW_PI_HOST=5a
KTHW_SSH_CA_KEY="$HOME/.ssh/ca.pub"
KTHW_DEBIAN_IMAGE="https://cloud.debian.org/images/cloud/bookworm/20240717-1811/debian-12-genericcloud-arm64-20240717-1811.qcow2"
KTHW_POD_CIDR0=10.200.0.0/24
KTHW_POD_CIDR1=10.200.1.0/24
