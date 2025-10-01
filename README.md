# proxmox-ova-import

A robust Bash script to import **OVA** appliances into **Proxmox VE**. It extracts OVF/VMDKs, imports all disks (largest as system disk), auto-detects **BIOS vs. UEFI**, selects a suitable **disk bus** (SCSI/SATA), sets **boot order**, configures **network**, and optionally boots a **Rescue ISO** for maintenance/password recovery (for systems you own/manage).

## Features

* 🔍 OVF parsing to infer **UEFI/BIOS** and preferred **disk bus**
* 💾 Imports **all** VMDKs (keeps layout; picks largest as system disk)
* 🔗 Attaches disks to **virtio-scsi** (default) or **SATA/IDE**
* 🚀 Sets **boot order** to the system disk
* 🌐 Configures `net0` (default `virtio,bridge=vmbr0`)
* 🛟 Optional **Rescue ISO** boot workflow for legit recovery
* 🧰 Sensible defaults; overridable via CLI flags

## Requirements

* Proxmox VE host shell
* `tar`, `qm`, `qemu-img`, `awk`
* An available **storage** (e.g., `local-lvm`, `local`, ZFS pool)
* OVA file accessible on the host

## Installation

```bash
curl -O https://raw.githubusercontent.com/<you>/<repo>/main/proxmox-ova-import.sh
chmod +x proxmox-ova-import.sh
```

## Usage

```bash
./proxmox-ova-import.sh \
  --vmid <ID> \
  --name "<VM-NAME>" \
  --storage <STORAGE-ID> \
  --ova /path/to/image.ova \
  [--memory MB] [--cores N] [--sockets N] \
  [--uefi | --bios seabios|ovmf] \
  [--disk-bus scsi|sata|ide] \
  [--net virtio|e1000|rtl8139] \
  [--keep-temp]
```

### Common examples

**Basic import (auto-detect firmware & bus)**

```bash
./proxmox-ova-import.sh --vmid 200 --name "AppVM" --storage local-lvm --ova /root/app.ova
```

**Force UEFI (OVMF)**

```bash
./proxmox-ova-import.sh --vmid 201 --name "UEFI-VM" --storage local-lvm --ova /root/app.ova --uefi
```

**VirtualBox-style guest (SeaBIOS + SATA + e1000)**

```bash
./proxmox-ova-import.sh --vmid 202 --name "VBox-Guest" --storage local-lvm --ova /root/app.ova \
  --bios seabios --disk-bus sata --net e1000
```

## Optional Rescue ISO workflow

If you need legitimate admin recovery/maintenance:

1. Upload a rescue ISO (e.g., `systemrescue.iso`) to a Proxmox ISO storage.
2. Attach and boot from it (use the companion script or `qm set --ide2 STORAGE:iso/... --boot order=ide2`).
3. In the rescue shell, mount the root FS, `chroot`, and run:

   ```bash
   passwd root
   # or: echo "root:NewPassword" | chpasswd
   ```
4. Remove ISO and set boot order back to the system disk.

> **Note:** Only use this on systems you own or are explicitly authorized to administer.

## Tips & Troubleshooting

* **No bootable device**
  Try switching bus/controller:

  * `--disk-bus sata` (VirtualBox-origin images often prefer SATA)
  * For UEFI guests: `--uefi` (adds OVMF + EFI disk)
  * Re-check boot order: `qm set <VMID> --boot order=<bus>0` (e.g., `sata0`, `scsi0`)

* **Multiple VMDKs**
  The script imports all; the **largest** is assumed to be the system disk and attached as `*0`.

* **Network unreachable**
  Ensure your bridge (default `vmbr0`) is correct and the guest has drivers (for Windows guests you may prefer `--net e1000`).

* **Windows guests**
  If switching to VirtIO, install VirtIO drivers in the **source** VM first. Otherwise use SATA/e1000 initially.

* **LVM/Encrypted root**
  In rescue mode, run `vgchange -ay` for LVM or unlock LUKS volumes before mounting.

## CLI Options (summary)

* `--vmid` (required): Target Proxmox VMID
* `--name` (required): VM name
* `--storage` (required): Storage ID for disks (e.g., `local-lvm`)
* `--ova` (required): Path to OVA
* `--memory`, `--cores`, `--sockets`: Compute sizing
* `--uefi` / `--bios`: Force firmware
* `--disk-bus`: `scsi` (default), `sata`, or `ide`
* `--net`: NIC model, default `virtio`
* `--keep-temp`: Keep extracted OVF/VMDKs for debugging

## Example: VulnHub “The Planets: Earth”

Recommended start:

```bash
./proxmox-ova-import.sh \
  --vmid 200 \
  --name "VulnHub-Earth" \
  --storage local-lvm \
  --ova /root/Earth.ova \
  --bios seabios \
  --disk-bus sata \
  --net e1000
```

## Security & Ethics

This project is intended for **lawful administration** and **disaster recovery** of systems you own or are authorized to manage. Do **not** use it to bypass security on third-party systems.

## Contributing

Issues and PRs are welcome. Please describe your environment (Proxmox version, storage type, guest OS) and include command output (`qm config <VMID>`).

## License

MIT 
