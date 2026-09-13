# AryanaNet — Ubuntu VPS to MikroTik CHR Installer

Automatically converts a supported Ubuntu VPS into MikroTik Cloud Hosted Router (CHR).

## ⚠️ WARNING

This installer is DESTRUCTIVE.

It permanently erases the current system disk and replaces Ubuntu with MikroTik CHR.

All files, partitions, operating system data and other data stored on the target disk will be destroyed.

Make sure you have a backup before continuing.

## Requirements

- Ubuntu Server 20.04 / 22.04 / 24.04 / 26.04 LTS
- x86_64 architecture
- Full virtual machine
- KVM / QEMU / Xen / VMware / Hyper-V compatible environment
- Legacy BIOS boot mode
- At least 256 MB RAM
- Recommended: 1024 MB RAM or more
- IPv4 configuration with a detectable default gateway

## Supported CHR Version

MikroTik CHR Long-term:

7.23.5

## Installation

Run:

```bash
curl -fsSL https://raw.githubusercontent.com/nawidsadeghi/ubuntu-chr/refs/heads/main/install-chr.sh \
-o /tmp/install-chr.sh && \
chmod 700 /tmp/install-chr.sh && \
sudo /tmp/install-chr.sh
