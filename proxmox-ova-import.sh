#!/usr/bin/env bash
set -euo pipefail

# proxmox-ova-import.sh
# A robust Bash script to import an OVA into Proxmox VE:
# - extracts OVF/VMDKs
# - imports all VMDKs (largest assumed system disk)
# - attaches disks using an appropriate bus (scsi/sata/ide)
# - auto-detects BIOS vs. UEFI (OVF heuristic) and can override
# - sets boot order to the system disk
# - configures a network device (default virtio)
# - optionally attaches a Rescue ISO and boots the VM from CD for maintenance
#
# Requirements: run on a Proxmox host shell as root (or sudo)
# - tar, qm, qemu-img, awk
#
# Usage example:
# ./proxmox-ova-import.sh --vmid 200 --name "Imported-VM" --storage local-lvm --ova /path/to/image.ova
# Optional rescue ISO:
# ./proxmox-ova-import.sh ... --rescue-iso local:iso/systemrescue.iso
#
# CLI flags:
# --vmid        (required) target Proxmox VMID
# --name        (required) VM name
# --storage     (required) storage identifier for disks (e.g., local-lvm, local, zfspool)
# --ova         (required) path to OVA file on Proxmox host
# --memory      RAM in MB (default 4096)
# --cores       vCPU cores (default 2)
# --sockets     CPU sockets (default 1)
# --uefi        force UEFI (ovmf)
# --bios        override firmware: seabios|ovmf
# --disk-bus    scsi|sata|ide  (default: auto-detect, fallback to scsi)
# --net         virtio|e1000|rtl8139 (default virtio)
# --keep-temp   keep extracted OVA files for debugging
# --rescue-iso  storage:iso-path (optional, attach ISO as ide2 and boot from it)
# --help        show usage
#
# Exit codes:
# 0 success, non-zero on error

usage() {
  cat <<'EOF'
proxmox-ova-import.sh

Usage:
  proxmox-ova-import.sh --vmid <ID> --name <NAME> --storage <STORAGE> --ova <PATH.ova> [options]

Required:
  --vmid        Proxmox VMID (e.g. 200)
  --name        VM name
  --storage     Proxmox storage ID for disks (e.g. local-lvm)
  --ova         Path to OVA file on the Proxmox host

Options:
  --memory MB       RAM in MB (default 4096)
  --cores N         CPU cores (default 2)
  --sockets N       CPU sockets (default 1)
  --uefi            Force UEFI firmware (OVMF)
  --bios seabios|ovmf
  --disk-bus scsi|sata|ide  Override disk bus
  --net virtio|e1000|rtl8139  Network model (default virtio)
  --keep-temp       Keep extracted OVA files in temp dir
  --rescue-iso STORAGE:iso-name.iso  Attach Rescue ISO (as ide2) and set boot to CD
  -h, --help        show this help
EOF
}

# Defaults
VMID=""
NAME=""
STORAGE=""
OVA=""
MEMORY=4096
CORES=2
SOCKETS=1
FORCE_UEFI=0
BIOS_OVERRIDE=""
DISK_BUS_OVERRIDE=""
NET_MODEL="virtio"
KEEP_TEMP=0
RESCUE_ISO=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --ova) OVA="$2"; shift 2;;
    --memory) MEMORY="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --sockets) SOCKETS="$2"; shift 2;;
    --uefi) FORCE_UEFI=1; shift;;
    --bios) BIOS_OVERRIDE="$2"; shift 2;;
    --disk-bus) DISK_BUS_OVERRIDE="$2"; shift 2;;
    --net) NET_MODEL="$2"; shift 2;;
    --keep-temp) KEEP_TEMP=1; shift;;
    --rescue-iso) RESCUE_ISO="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

# Basic validation
if [[ -z "${VMID}" || -z "${NAME}" || -z "${STORAGE}" || -z "${OVA}" ]]; then
  echo "Error: missing required argument."
  usage
  exit 1
fi

if [[ ! -f "${OVA}" ]]; then
  echo "Error: OVA file not found: ${OVA}"
  exit 1
fi

# Create temp dir for extraction
TMPDIR="$(mktemp -d -t ovaimp-XXXXXX)"
cleanup() {
  if [[ $KEEP_TEMP -eq 0 ]]; then
    rm -rf "${TMPDIR}"
  else
    echo "Temporary files retained at: ${TMPDIR}"
  fi
}
trap cleanup EXIT

echo ">> Extracting OVA into ${TMPDIR} ..."
tar -xf "${OVA}" -C "${TMPDIR}"

# Find OVF & VMDKs
OVF="$(find "${TMPDIR}" -maxdepth 1 -type f -iname '*.ovf' | head -n1 || true)"
mapfile -t VMDKS < <(find "${TMPDIR}" -maxdepth 1 -type f -iname '*.vmdk' -print | sort)

if [[ ${#VMDKS[@]} -eq 0 ]]; then
  echo "Error: no VMDK files found inside the OVA."
  exit 1
fi

# Heuristics: detect UEFI and disk bus from OVF if present
UEFI=0
BUS="scsi"  # default
if [[ -n "${OVF}" ]]; then
  if grep -qiE 'firmware.*efi|ovf:firmware.*efi' "${OVF}" 2>/dev/null || grep -qi 'vmw:key="firmware".*value="efi"' "${OVF}" 2>/dev/null; then
    UEFI=1
  fi
  # basic detection of SATA keyword in OVF
  if grep -qi 'sata' "${OVF}" 2>/dev/null; then
    BUS="sata"
  elif grep -qi 'lsilogic' "${OVF}" 2>/dev/null; then
    BUS="scsi"
  fi
else
  echo ">> Warning: no OVF found, firmware/bus detection is limited."
fi

# Apply overrides
if [[ -n "${BIOS_OVERRIDE}" ]]; then
  case "${BIOS_OVERRIDE}" in
    seabios) UEFI=0;;
    ovmf) UEFI=1;;
    *) echo "Error: --bios accepts only 'seabios' or 'ovmf'"; exit 1;;
  esac
fi
if [[ ${FORCE_UEFI} -eq 1 ]]; then
  UEFI=1
fi
if [[ -n "${DISK_BUS_OVERRIDE}" ]]; then
  case "${DISK_BUS_OVERRIDE}" in
    scsi|sata|ide) BUS="${DISK_BUS_OVERRIDE}";;
    *) echo "Error: --disk-bus accepts scsi|sata|ide"; exit 1;;
  esac
fi

echo ">> Firmware: $(( UEFI )) && echo 'OVMF/UEFI' || echo 'SeaBIOS'"
if (( UEFI )); then
  echo ">> Using firmware: OVMF (UEFI)"
else
  echo ">> Using firmware: SeaBIOS"
fi
echo ">> Preferred disk bus: ${BUS}"
echo ">> Network model: ${NET_MODEL}"

# Determine sizes of VMDKs and sort descending (largest first)
declare -A VMDK_SIZE
for v in "${VMDKS[@]}"; do
  if ! qemu-img info --output=json "$v" >/dev/null 2>&1; then
    # If qemu-img cannot parse, fallback to file size
    filesize=$(stat -c%s "$v" || echo 0)
    VMDK_SIZE["$v"]="${filesize}"
  else
    # qemu-img returns JSON with "virtual-size"
    vsize=$(qemu-img info --output=json "$v" 2>/dev/null | awk -F'[,:}]' '/"virtual-size"/{gsub(/ /,"",$2); print $2}')
    VMDK_SIZE["$v"]="${vsize:-0}"
  fi
done

# sort vmdks by size desc
readarray -t VMDKS_SORTED < <(for v in "${VMDKS[@]}"; do echo -e "${VMDK_SIZE[$v]:-0}\t$v"; done | sort -rn | cut -f2-)

SYSTEM_VMDK="${VMDKS_SORTED[0]}"
echo ">> Selected system disk (largest VMDK): $(basename "${SYSTEM_VMDK}")"

# Create VM (without disks)
echo ">> Creating VM ${VMID} (name: ${NAME}) ..."
qm create "${VMID}" --name "${NAME}" --memory "${MEMORY}" --cores "${CORES}" --sockets "${SOCKETS}" --ostype l26

# Network config (default bridge vmbr0)
qm set "${VMID}" --net0 "${NET_MODEL},bridge=vmbr0"

# Firmware/EFI config
if (( UEFI )); then
  qm set "${VMID}" --bios ovmf
  # Add small efidisk metadata (only if storage allows small volume)
  # Use efidisk0 only if the storage supports small files; Proxmox will allocate minimal
  qm set "${VMID}" --efidisk0 "${STORAGE}:0,pre-enrolled-keys=1" || true
else
  qm set "${VMID}" --bios seabios
fi

# Add SCSI controller if chosen
if [[ "${BUS}" == "scsi" ]]; then
  qm set "${VMID}" --scsihw virtio-scsi-single
fi

# Import all VMDKs and attach them in order (largest -> bus0)
INDEX=0
for vmdk in "${VMDKS_SORTED[@]}"; do
  echo ">> Importing VMDK: $(basename "$vmdk") -> storage ${STORAGE}"
  qm importdisk "${VMID}" "${vmdk}" "${STORAGE}" --format qcow2 >/dev/null

  # Find the last 'unusedN' entry in qm config
  UNUSED_LINE="$(qm config "${VMID}" | awk '/^unused[0-9]+: /{print $0}' | tail -n1 || true)"
  if [[ -z "${UNUSED_LINE}" ]]; then
    echo "Error: could not find imported disk reference (unusedN)."
    exit 1
  fi
  DISK_REF="$(echo "${UNUSED_LINE}" | awk -F': ' '{print $2}')"

  # Define target slot based on chosen bus and index
  TARGET="${BUS}${INDEX}"

  echo ">> Attaching disk ${DISK_REF} as ${TARGET}"
  qm set "${VMID}" --${TARGET} "${DISK_REF}"

  ((INDEX++))
done

# Set boot order to the first attached disk (bus0)
BOOT_TARGET="${BUS}0"
echo ">> Setting boot order to ${BOOT_TARGET}"
qm set "${VMID}" --boot order="${BOOT_TARGET}"

# Make serial console friendly
qm set "${VMID}" --serial0 socket --vga serial0

# If Rescue ISO requested: attach it as ide2 and boot from CD
if [[ -n "${RESCUE_ISO}" ]]; then
  echo ">> Attaching Rescue ISO ${RESCUE_ISO} to VM ${VMID} (ide2) and setting boot order to CD"
  qm set "${VMID}" --ide2 "${RESCUE_ISO},media=cdrom"
  # Set boot to cdrom first (ide2)
  qm set "${VMID}" --boot order=ide2
fi

echo ">> VM ${VMID} created and disks attached."
if [[ -n "${RESCUE_ISO}" ]]; then
  echo ">> Rescue ISO attached. Start the VM and connect to VM console to perform maintenance."
fi

echo "You can start the VM now with:"
echo "  qm start ${VMID}"

if [[ -n "${RESCUE_ISO}" ]]; then
  echo ""
  cat <<EOF
Maintenance notes for rescue boot:
 - Connect to the VM console via the Proxmox web UI -> Console, or use 'qm terminal ${VMID}' if supported.
 - Inside the rescue/live environment:
   1) Identify disks/partitions: lsblk, fdisk -l
   2) If LVM is used: vgchange -ay
   3) Mount the root filesystem (replace /dev/sdXN with your root partition):
      mkdir -p /mnt/groot
      mount /dev/sdXN /mnt/groot
   4) Bind system dirs for chroot:
      mount --bind /dev /mnt/groot/dev
      mount --bind /proc /mnt/groot/proc
      mount --bind /sys  /mnt/groot/sys
   5) chroot:
      chroot /mnt/groot /bin/bash
   6) Reset root password:
      passwd root
      # OR:
      echo "root:NewPassword" | chpasswd
   7) If needed, update grub (Debian/Ubuntu):
      update-grub
   8) Cleanup & unmount, then shutdown the rescue environment.
 - After finishing:
   qm set ${VMID} --ide2 none,media=cdrom
   qm set ${VMID} --boot order=${BOOT_TARGET}
   qm stop ${VMID} || true
   qm start ${VMID}
EOF
fi

exit 0
