# proxmox-ova-import

A robust Bash script to import **OVA appliances** into **Proxmox VE**.

It extracts OVF/VMDKs, imports all disks (largest assumed as system disk), auto-detects **BIOS vs. UEFI**, selects an appropriate **disk bus** (SCSI/SATA/IDE), sets **boot order**, configures **network**, and can optionally boot from a **Rescue ISO** for maintenance or password recovery of systems you own/manage.

---

## ✨ Features
- 🔍 OVF parsing to infer **UEFI/BIOS** and preferred **disk bus**
- 💾 Imports **all VMDKs** (largest treated as system disk)
- 🔗 Attaches disks via **virtio-scsi** (default) or **SATA/IDE**
- 🚀 Sets **boot order** automatically
- 🌐 Configures `net0` (default `virtio,bridge=vmbr0`)
- 🛟 Optional **Rescue ISO** boot for recovery and administration
- 🧰 CLI options for memory, CPU, NIC model, bus type, firmware overrides

---

## 📦 Requirements
- Proxmox VE host shell access  
- Tools: `tar`, `qm`, `qemu-img`, `awk`  
- OVA file accessible on the Proxmox host  
- An available Proxmox **storage** (e.g. `local-lvm`, `local`, ZFS pool)  

---

## 🚀 Installation
```bash
curl -O https://raw.githubusercontent.com/<your-user>/<your-repo>/main/proxmox-ova-import.sh
chmod +x proxmox-ova-import.sh
````

---

## ⚙️ Usage

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
  [--keep-temp] \
  [--rescue-iso storage:iso/systemrescue.iso]
```

### Common examples

**Basic import (auto-detect firmware & bus):**

```bash
./proxmox-ova-import.sh --vmid 200 --name "AppVM" --storage local-lvm --ova /root/app.ova
```

**Force UEFI (OVMF):**

```bash
./proxmox-ova-import.sh --vmid 201 --name "UEFI-VM" --storage local-lvm --ova /root/app.ova --uefi
```

**VirtualBox-style guest (SeaBIOS + SATA + e1000):**

```bash
./proxmox-ova-import.sh --vmid 202 --name "VBox-Guest" --storage local-lvm --ova /root/app.ova \
  --bios seabios --disk-bus sata --net e1000
```

**Import and immediately boot into a rescue ISO:**

```bash
./proxmox-ova-import.sh --vmid 203 --name "Rescue-VM" --storage local-lvm --ova /root/app.ova \
  --rescue-iso local:iso/systemrescue.iso
qm start 203
```

---

## 🛟 Rescue ISO workflow (optional)

If you need to perform **legitimate maintenance or recovery**:

1. Upload a rescue ISO (e.g. `systemrescue.iso`, `ubuntu-live.iso`) into a Proxmox ISO storage.
2. Run the script with `--rescue-iso storage:iso/filename.iso`.
3. The VM will be configured to boot from CD (ide2).
4. Start the VM and connect to its console.
5. Inside the rescue system:

   ```bash
   lsblk                          # find root partition
   mount /dev/sdXN /mnt/groot
   mount --bind /dev /mnt/groot/dev
   mount --bind /proc /mnt/groot/proc
   mount --bind /sys  /mnt/groot/sys
   chroot /mnt/groot /bin/bash
   passwd root                    # or: echo "root:NewPass" | chpasswd
   ```
6. Remove ISO and reset boot order:

   ```bash
   qm set <VMID> --ide2 none,media=cdrom
   qm set <VMID> --boot order=sata0   # or scsi0 depending on disk bus
   qm stop <VMID>
   qm start <VMID>
   ```

---

## 🛠 Troubleshooting

* **No bootable device**

  * Try `--disk-bus sata` (VirtualBox images often expect SATA).
  * Use `--uefi` if the guest requires UEFI.
  * Re-check boot order: `qm set <VMID> --boot order=sata0` (or scsi0/ide0).

* **Multiple VMDKs**
  The script imports all VMDKs. The largest is assumed as the boot/system disk.

* **Windows guests**
  If you want to use VirtIO, install VirtIO drivers in the original VM before migration. Otherwise, use SATA/e1000 initially.

* **Encrypted or LVM root**
  Use rescue mode and run `vgchange -ay` for LVM or unlock LUKS before mounting.

---

## 🔑 Security & Ethics

This project is intended for **lawful administration** and **disaster recovery** of systems you **own or are authorized to manage**.
Do **not** use it to bypass security on third-party systems.

---

## 📄 License

MIT License — see `LICENSE` file.

---

## 🤝 Contributing

Issues and PRs are welcome! Please include:

* Proxmox VE version
* Guest OS type
* Storage backend
* Output of `qm config <VMID>` if relevant


