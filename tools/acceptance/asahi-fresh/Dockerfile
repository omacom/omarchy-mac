FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  dosfstools \
  e2fsprogs \
  fdisk \
  gnupg \
  libarchive-tools \
  openssh-client \
  parted \
  qemu-efi-aarch64 \
  qemu-system-arm \
  qemu-utils \
  socat \
  udev \
  && rm -rf /var/lib/apt/lists/*

COPY container/ /usr/local/lib/omarchy-asahi-vm/
