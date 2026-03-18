# Build the Packer/Vagrant build environment image.
#
# Base image: ghcr.io/vagrant-libvirt/vagrant-libvirt:0.12.2
#   Source:   https://github.com/vagrant-libvirt/vagrant-libvirt
#   Contains: Vagrant 2.x + vagrant-libvirt plugin + gosu entrypoint
#
# Build arguments (all have defaults):
#   BASE_IMAGE      — base image
#   PACKER_VER      — Packer version to install
#   QEMU_PLUGIN_VER — packer-plugin-qemu version
#   TIMEZONE        — system timezone
#
# Build:
#   make docker-build
#   # or manually:
#   docker build -t packer-vagrant docker/
#
# Test manually:
#   docker run -it --rm --privileged --network host \
#     --device /dev/kvm \
#     -v ~/.vagrant.d:/.vagrant.d \
#     -v /var/lib/libvirt:/var/lib/libvirt:rw \
#     -v /var/run/libvirt:/var/run/libvirt:rw \
#     -v $PWD:$PWD -w $PWD \
#     -e PACKER_LOG=1 \
#     -e IGNORE_MISSING_LIBVIRT_SOCK=1 \
#     packer-vagrant \
#     packer build templates/vendor-base/ubuntu-24.04/packer.json

ARG BASE_IMAGE=ghcr.io/vagrant-libvirt/vagrant-libvirt:0.12.2
FROM ${BASE_IMAGE}

ARG PACKER_VER=1.11.1
ARG QEMU_PLUGIN_VER=1.1.0
ARG TIMEZONE=Asia/Jerusalem

ENV DEBIAN_FRONTEND=noninteractive \
    PACKER_PLUGIN_PATH=/usr/local/share/packer/plugins

RUN apt-get update && apt-get install -y \
    sudo \
    wget \
    unzip \
    curl \
    qemu-utils \
    qemu-system-x86 \
    ovmf \
    python3 \
    python3-pip \
    software-properties-common \
  && rm -rf /var/lib/apt/lists/*

RUN echo "${TIMEZONE}" > /etc/timezone

# Install Packer
RUN wget -q -O /tmp/packer.zip \
    "https://releases.hashicorp.com/packer/${PACKER_VER}/packer_${PACKER_VER}_linux_amd64.zip" \
  && unzip -o /tmp/packer.zip -d /usr/local/bin \
  && rm -f /tmp/packer.zip \
  && packer version

# Install packer plugins (required SHA256SUM sidecar via 'packer plugins install')
ARG VAGRANT_PLUGIN_VER=1.1.5
ARG ANSIBLE_PLUGIN_VER=1.1.2
RUN mkdir -p /usr/local/share/packer/plugins \
 && chmod 755 /usr/local/share/packer/plugins \
 && packer plugins install github.com/hashicorp/qemu ${QEMU_PLUGIN_VER} \
 && packer plugins install github.com/hashicorp/vagrant ${VAGRANT_PLUGIN_VER} \
 && packer plugins install github.com/hashicorp/ansible ${ANSIBLE_PLUGIN_VER} \
 && chmod -R a+rX /usr/local/share/packer/plugins

# Install Ansible (for org-golden builds)
RUN add-apt-repository --yes --update ppa:ansible/ansible \
  && apt-get install -y ansible \
  && rm -rf /var/lib/apt/lists/*

RUN echo 'vagrant ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
