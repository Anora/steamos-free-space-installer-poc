#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# SteamOS free-space PC installer proof-of-concept v2.
#
# Purpose:
#   Install SteamOS into an existing unallocated/free space region on a GPT disk
#   without deleting existing Windows/data partitions.
#
# Based on Valve's SteamOS recovery repair_device.sh flow, but with the dangerous
# whole-disk wipe/sanitize paths removed and replaced with an interactive free
# space picker.
#
# WARNING:
#   This is experimental. It still writes a partition table, formats new
#   partitions, and images SteamOS. Back up important data before using it.
#   Run from the SteamOS recovery environment, not from an installed SteamOS
#   system on the same target disk.

set -euo pipefail

[[ ${EUID-} = 0 ]] || exec sudo -- "$0" "$@"

readvar() { IFS= read -r -d '' "$1" || true; }

die()  { echo >&2 "!! $*"; exit 1; }
warn() { echo >&2 ";; $*"; }
info() { echo >&2 ":: $*"; }
showcmd() { echo >&2 "+ ${*@Q}"; }
cmd() { showcmd "$@"; "$@"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ----- SteamOS partition sizes -----
# These match Valve's recovery script defaults for the system partitions.
PART_SIZE_ESP=256
PART_SIZE_EFI=64
PART_SIZE_ROOT=5120
PART_SIZE_VAR=256
# Home receives all remaining space in the selected free region.
MIN_HOME_MIB="${MIN_HOME_MIB:-32768}"
SKIP_JUPITER_UPDATES="${SKIP_JUPITER_UPDATES:-1}"
DOPARTVERIFY=0

# GPT partition type GUIDs used by Valve's script.
GUID_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
GUID_EFI="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
GUID_ROOT="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"
GUID_VAR="4D21B016-B534-45C2-A9FB-5C16E091FD2D"
GUID_HOME="933AC7E1-2EB4-4F13-B844-0E14E2AEF915"

fixed_mib=$(( PART_SIZE_ESP + 2*PART_SIZE_EFI + 2*PART_SIZE_ROOT + 2*PART_SIZE_VAR ))
MIN_TOTAL_MIB=$(( fixed_mib + MIN_HOME_MIB + 16 ))

DISK=""
DISK_SUFFIX=""
FS_ESP=""
FS_EFI_A=""
FS_EFI_B=""
FS_ROOT_A=""
FS_ROOT_B=""
FS_VAR_A=""
FS_VAR_B=""
FS_HOME=""
DRY_RUN=0
SETUP_BOOT_MENU=0
BOOT_MENU_TIMEOUT="${BOOT_MENU_TIMEOUT:-8}"

# Scan result arrays. Each index represents one installable free-space region.
declare -a CHOICE_DISK CHOICE_START CHOICE_END CHOICE_SIZE CHOICE_DESC
declare -a WIN_DEV WIN_UUID WIN_DISK WIN_DESC

usage() {
  cat <<USAGE
SteamOS free-space PC installer proof-of-concept

Usage:
  sudo $0 scan
  sudo $0 install
  sudo $0 install --dry-run
  sudo $0 install --setup-boot-menu
  sudo $0 scan-windows
  sudo $0 boot-menu
  sudo $0 boot-menu --dry-run

What it does:
  - Scans GPT disks for unallocated/free space large enough for SteamOS.
  - Lets you pick one free-space location.
  - Creates SteamOS partitions only inside that chosen free space.
  - Formats and images SteamOS to those new partitions.
  - Optionally creates a SteamOS GRUB custom.cfg boot menu entry for Windows.

What it does NOT do:
  - It does not sanitize a drive.
  - It does not rewrite a whole disk partition table.
  - It does not delete existing Windows/data partitions.
  - It does not modify Windows Boot Manager or Windows BCD.

Minimum free space currently required:
  ${MIN_TOTAL_MIB} MiB total, including at least ${MIN_HOME_MIB} MiB for /home.
  Override example: MIN_HOME_MIB=65536 sudo $0 install

Boot menu commands:
  scan-windows  : show detected Windows Boot Manager locations and likely Windows NTFS volumes.
  boot-menu     : create/update SteamOS GRUB custom.cfg with Windows entries.
  install --setup-boot-menu : install SteamOS, then attempt to create the boot menu.
USAGE
}

# ----- small helpers -----

disk_suffix_for() { [[ "$1" =~ [0-9]$ ]] && printf 'p' || true; }
diskpart() { echo "${DISK}${DISK_SUFFIX}$1"; }

mib_to_sectors() {
  local mib="$1" sector_size="$2"
  echo $(( mib * 1024 * 1024 / sector_size ))
}

align_up() {
  local value="$1" align="$2"
  echo $(( ((value + align - 1) / align) * align ))
}

sector_to_mib_floor() {
  local sectors="$1" sector_size="$2"
  echo $(( sectors * sector_size / 1024 / 1024 ))
}

root_disk_path() {
  local rootdev pk
  rootdev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$rootdev" ]] || return 1
  pk="$(lsblk -no PKNAME "$rootdev" 2>/dev/null | tail -n1 || true)"
  [[ -n "$pk" ]] || return 1
  echo "/dev/$pk"
}

is_gpt_disk() {
  local disk="$1"
  parted -ms "$disk" print 2>/dev/null | awk -F: 'NR==2 { exit ($6 == "gpt" ? 0 : 1) }'
}

has_existing_steamos_labels() {
  local disk="$1"
  lsblk -nrpo PARTLABEL "$disk" 2>/dev/null | grep -Eq '^(esp|efi-A|efi-B|rootfs-A|rootfs-B|var-A|var-B|home)$'
}

print_disk_tree() {
  local disk="$1"
  lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$disk"
}

# ----- Windows / boot menu helpers -----

cleanup_mounts=()
cleanup_extra_mounts() {
  local m
  for m in "${cleanup_mounts[@]:-}"; do
    mountpoint -q "$m" && umount "$m" || true
    rmdir "$m" 2>/dev/null || true
  done
}
trap cleanup_extra_mounts EXIT

first_mountpoint_for() {
  local dev="$1" mp
  # findmnt returns one line per mount. We only need the first target.
  mp="$(findmnt -nr -S "$dev" -o TARGET 2>/dev/null | head -n1 || true)"
  [[ -n "$mp" ]] && echo "$mp"
}

mount_part_temp() {
  local dev="$1" mode="${2:-ro}" mp
  mp="$(first_mountpoint_for "$dev" || true)"
  if [[ -n "$mp" ]]; then
    echo "$mp"
    return 0
  fi
  mp="$(mktemp -d /tmp/steamos-installer-mount.XXXXXX)"
  if [[ "$mode" == "rw" ]]; then
    mount "$dev" "$mp"
  else
    mount -o ro "$dev" "$mp"
  fi
  cleanup_mounts+=("$mp")
  echo "$mp"
}

part_info_one_line() {
  local dev="$1" disk size label partlabel uuid fstype
  disk="/dev/$(lsblk -no PKNAME "$dev" 2>/dev/null | tail -n1)"
  size="$(lsblk -dnpo SIZE "$dev" 2>/dev/null | awk '{$1=$1;print}')"
  fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
  label="$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
  partlabel="$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || true)"
  uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
  printf '%s size=%s fstype=%s uuid=%s label="%s" partlabel="%s" disk=%s' "$dev" "$size" "$fstype" "$uuid" "$label" "$partlabel" "$disk"
}

list_ntfs_on_disk() {
  local disk="$1" part type size label partlabel
  while IFS= read -r part; do
    type="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
    [[ "$type" == "ntfs" ]] || continue
    size="$(lsblk -dnpo SIZE "$part" 2>/dev/null | awk '{$1=$1;print}')"
    label="$(blkid -s LABEL -o value "$part" 2>/dev/null || true)"
    partlabel="$(blkid -s PARTLABEL -o value "$part" 2>/dev/null || true)"
    printf '      - %s size=%s label="%s" partlabel="%s"\n' "$part" "$size" "$label" "$partlabel"
  done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2 == "part" { print $1 }')
}

scan_windows_bootmanagers() {
  WIN_DEV=(); WIN_UUID=(); WIN_DISK=(); WIN_DESC=()
  require_cmd lsblk
  require_cmd blkid
  require_cmd mount

  local part type mp uuid disk disk_desc desc
  while IFS= read -r part; do
    type="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
    [[ "$type" == "vfat" || "$type" == "fat" || "$type" == "msdos" ]] || continue
    mp="$(mount_part_temp "$part" ro 2>/dev/null || true)"
    [[ -n "$mp" ]] || continue
    if [[ -f "$mp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
      uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
      disk="/dev/$(lsblk -no PKNAME "$part" 2>/dev/null | tail -n1)"
      disk_desc="$(lsblk -dnpo NAME,SIZE,MODEL,SERIAL "$disk" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
      desc="Windows Boot Manager on $(part_info_one_line "$part") | $disk_desc"
      WIN_DEV+=("$part")
      WIN_UUID+=("$uuid")
      WIN_DISK+=("$disk")
      WIN_DESC+=("$desc")
    fi
  done < <(lsblk -nrpo NAME,TYPE | awk '$2 == "part" { print $1 }')
}

print_windows_bootmanagers() {
  scan_windows_bootmanagers
  echo
  echo "Detected Windows boot locations:"
  if (( ${#WIN_DEV[@]} == 0 )); then
    echo "  none found"
    echo "  Expected file: /EFI/Microsoft/Boot/bootmgfw.efi on a FAT EFI System Partition."
    return 1
  fi

  local i
  for i in "${!WIN_DEV[@]}"; do
    printf '  [%d] %s\n' "$((i+1))" "${WIN_DESC[$i]}"
    echo "      Likely Windows NTFS partitions on same disk (${WIN_DISK[$i]}):"
    list_ntfs_on_disk "${WIN_DISK[$i]}"
  done
}

# Return SteamOS EFI directories containing EFI/steamos/grub.cfg, one per line.
# It checks currently mounted paths and then SteamOS efi-A/efi-B partitions.
find_steamos_grub_dirs() {
  local seen="" d part partlabel type mp

  for d in /efi/EFI/steamos /esp/EFI/steamos /boot/efi/EFI/steamos; do
    if [[ -f "$d/grub.cfg" ]]; then
      echo "$d"
      seen="$seen|$d|"
    fi
  done

  while IFS= read -r part; do
    type="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
    [[ "$type" == "vfat" || "$type" == "fat" || "$type" == "msdos" ]] || continue
    partlabel="$(blkid -s PARTLABEL -o value "$part" 2>/dev/null || true)"
    [[ "$partlabel" == "efi-A" || "$partlabel" == "efi-B" ]] || continue
    mp="$(mount_part_temp "$part" rw 2>/dev/null || true)"
    [[ -n "$mp" ]] || continue
    d="$mp/EFI/steamos"
    if [[ -f "$d/grub.cfg" && "$seen" != *"|$d|"* ]]; then
      echo "$d"
      seen="$seen|$d|"
    fi
  done < <(lsblk -nrpo NAME,TYPE | awk '$2 == "part" { print $1 }')
}

make_windows_grub_entry() {
  local idx="$1" title uuid dev disk line
  dev="${WIN_DEV[$idx]}"
  uuid="${WIN_UUID[$idx]}"
  disk="${WIN_DISK[$idx]}"
  title="Windows Boot Manager ($(basename "$dev") on $(basename "$disk"))"
  [[ -n "$uuid" ]] || die "Windows EFI partition $dev has no UUID."

  cat <<ENTRY
menuentry "$title" {
    insmod part_gpt
    insmod fat
    search --fs-uuid --no-floppy --set=root $uuid
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
ENTRY
}

generate_custom_cfg() {
  local i
  cat <<HEADER
# SteamOS PC dual-boot menu entries
# Generated by steamos_free_space_installer.sh on $(date -Is 2>/dev/null || date)
# Safe to delete if you want to remove the extra Windows boot entries.

set timeout_style=menu
set timeout=${BOOT_MENU_TIMEOUT}

HEADER
  for i in "${!WIN_DEV[@]}"; do
    echo "# ${WIN_DESC[$i]}"
    make_windows_grub_entry "$i"
    echo
  done
}

setup_grub_boot_menu() {
  scan_windows_bootmanagers
  print_windows_bootmanagers || die "No Windows Boot Manager found. Not writing custom.cfg."

  local grub_dirs=() d
  while IFS= read -r d; do
    grub_dirs+=("$d")
  done < <(find_steamos_grub_dirs)

  if (( ${#grub_dirs[@]} == 0 )); then
    die "Could not find SteamOS GRUB directory containing grub.cfg. Expected something like /efi/EFI/steamos."
  fi

  echo
  echo "SteamOS GRUB directories to update:"
  printf '  - %s\n' "${grub_dirs[@]}"
  echo
  echo "The script will write custom.cfg with Windows menu entries and timeout=${BOOT_MENU_TIMEOUT}."
  echo "It will NOT edit Windows Boot Manager or Windows BCD."

  if (( DRY_RUN == 1 )); then
    warn "Dry-run mode: generated custom.cfg would be:"
    echo "----------------------------------------"
    generate_custom_cfg
    echo "----------------------------------------"
    return 0
  fi

  local phrase="WRITE STEAMOS BOOT MENU"
  echo
  echo "To continue, type exactly: $phrase"
  read -r -p "> " confirm
  [[ "$confirm" == "$phrase" ]] || die "Cancelled."

  local cfg backup
  for d in "${grub_dirs[@]}"; do
    cfg="$d/custom.cfg"
    if [[ -f "$cfg" ]]; then
      backup="$cfg.backup.$(date +%Y%m%d-%H%M%S)"
      cmd cp -a "$cfg" "$backup"
    fi
    generate_custom_cfg > "$cfg"
    cmd sync
    echo "Wrote $cfg"
  done

  echo
  info "Boot menu setup complete. Reboot and choose the SteamOS UEFI entry to see the GRUB menu."
}

# parted -m lines with unit sectors are either:
#   partition: NUM:STARTs:ENDs:SIZEx:FS:NAME:FLAGS;
#   free:      STARTs:ENDs:SIZEx:free;
# This function records all free regions big enough to be useful.
scan_free_spaces() {
  CHOICE_DISK=(); CHOICE_START=(); CHOICE_END=(); CHOICE_SIZE=(); CHOICE_DESC=()

  require_cmd lsblk
  require_cmd parted
  require_cmd blockdev

  local recovery_disk=""
  recovery_disk="$(root_disk_path || true)"

  local disk
  while IFS= read -r disk; do
    [[ -b "$disk" ]] || continue

    if [[ -n "$recovery_disk" && "$disk" == "$recovery_disk" ]]; then
      continue
    fi
    is_gpt_disk "$disk" || continue
    has_existing_steamos_labels "$disk" && continue

    local sector_size one_mib_sector min_total_sectors
    sector_size="$(blockdev --getss "$disk")"
    one_mib_sector=$(( 1024 * 1024 / sector_size ))
    min_total_sectors="$(mib_to_sectors "$MIN_TOTAL_MIB" "$sector_size")"

    local disk_desc
    disk_desc="$(lsblk -dnpo NAME,SIZE,MODEL,SERIAL "$disk" | sed 's/[[:space:]]\+/ /g')"

    local line f1 f2 f3 f4 f5 start_s end_s size_s start end aligned_start avail
    while IFS= read -r line; do
      [[ "$line" == *free* ]] || continue
      IFS=: read -r f1 f2 f3 f4 f5 _ <<<"$line"
      if [[ "$f4" == free* ]]; then
        start_s="$f1"; end_s="$f2"; size_s="$f3"
      elif [[ "$f5" == free* ]]; then
        start_s="$f2"; end_s="$f3"; size_s="$f4"
      else
        continue
      fi
      start="${start_s%s}"; end="${end_s%s}"
      [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || continue

      aligned_start="$(align_up "$start" "$one_mib_sector")"
      if (( aligned_start > end )); then
        continue
      fi
      avail=$(( end - aligned_start + 1 ))
      if (( avail >= min_total_sectors )); then
        CHOICE_DISK+=("$disk")
        CHOICE_START+=("$aligned_start")
        CHOICE_END+=("$end")
        CHOICE_SIZE+=("$avail")
        local mib
        mib="$(sector_to_mib_floor "$avail" "$sector_size")"
        CHOICE_DESC+=("$disk_desc | free start=${aligned_start}s end=${end}s size≈${mib}MiB")
      fi
    done < <(parted -ms "$disk" unit s print free 2>/dev/null || true)
  done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" { print $1 }')
}

print_choices() {
  local i
  echo
  echo "Installable free-space locations:"
  if (( ${#CHOICE_DISK[@]} == 0 )); then
    echo "  none found"
    echo
    echo "Minimum required: ${MIN_TOTAL_MIB} MiB total."
    echo "Tip: shrink/delete another partition first, then leave the space unallocated."
    return 1
  fi

  for i in "${!CHOICE_DISK[@]}"; do
    printf '  [%d] %s\n' "$((i+1))" "${CHOICE_DESC[$i]}"
  done
}

select_choice() {
  scan_free_spaces
  print_choices || exit 1

  echo
  read -r -p "Pick target free-space number, or q to quit: " pick
  [[ "$pick" != "q" && "$pick" != "Q" ]] || die "Cancelled."
  [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid choice."
  local idx=$((pick-1))
  (( idx >= 0 && idx < ${#CHOICE_DISK[@]} )) || die "Choice out of range."

  DISK="${CHOICE_DISK[$idx]}"
  DISK_SUFFIX="$(disk_suffix_for "$DISK")"
  SELECTED_START="${CHOICE_START[$idx]}"
  SELECTED_END="${CHOICE_END[$idx]}"
  SELECTED_SIZE="${CHOICE_SIZE[$idx]}"
}

# ----- SteamOS install functions from Valve flow, with dangerous parts removed -----

fmt_ext4()  { [[ $# -eq 2 && -n $1 && -n $2 ]] || die "fmt_ext4 args"; cmd mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 && -n $1 && -n $2 ]] || die "fmt_fat32 args"; cmd mkfs.vfat -n"$1" "$2"; }

imageroot() {
  local srcroot="$1" newroot="$2"
  cmd dd if="$srcroot" of="$newroot" bs=128M status=progress oflag=sync
  cmd btrfstune -f -u "$newroot"
  cmd btrfs check "$newroot"
}

finalize_part() {
  local partset="$1"
  info "Finalizing install part $partset"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- mkdir /efi/SteamOS
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- mkdir -p /esp/SteamOS/conf
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- steamos-partsets /efi/SteamOS/partsets
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- steamos-bootconf create --image "$partset" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$partset"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- grub-mkimage
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- update-grub
}

partnum_from_dev() { basename "$1" | grep -oE '[0-9]+$'; }

partnum_by_partlabel() {
  local label="$1" dev
  dev="$(lsblk -nrpo NAME,PARTLABEL "$DISK" | awk -v label="$label" '$2 == label { print $1; exit }')"
  [[ -n "$dev" ]] || die "Could not find partition on $DISK with PARTLABEL=$label"
  partnum_from_dev "$dev"
}

discover_fs_partitions() {
  FS_ESP="$(partnum_by_partlabel esp)"
  FS_EFI_A="$(partnum_by_partlabel efi-A)"
  FS_EFI_B="$(partnum_by_partlabel efi-B)"
  FS_ROOT_A="$(partnum_by_partlabel rootfs-A)"
  FS_ROOT_B="$(partnum_by_partlabel rootfs-B)"
  FS_VAR_A="$(partnum_by_partlabel var-A)"
  FS_VAR_B="$(partnum_by_partlabel var-B)"
  FS_HOME="$(partnum_by_partlabel home)"

  info "Using SteamOS partition map on $DISK:"
  echo "  esp=$(diskpart "$FS_ESP") efi-A=$(diskpart "$FS_EFI_A") efi-B=$(diskpart "$FS_EFI_B")"
  echo "  rootfs-A=$(diskpart "$FS_ROOT_A") rootfs-B=$(diskpart "$FS_ROOT_B")"
  echo "  var-A=$(diskpart "$FS_VAR_A") var-B=$(diskpart "$FS_VAR_B") home=$(diskpart "$FS_HOME")"
}

create_partitions_in_selected_gap() {
  local sector_size one_mib_sector cur end fixed_sectors min_home_sectors home_sectors
  sector_size="$(blockdev --getss "$DISK")"
  one_mib_sector=$(( 1024 * 1024 / sector_size ))
  cur="$(align_up "$SELECTED_START" "$one_mib_sector")"
  end="$SELECTED_END"

  local esp_s efi_s root_s var_s
  esp_s="$(mib_to_sectors "$PART_SIZE_ESP" "$sector_size")"
  efi_s="$(mib_to_sectors "$PART_SIZE_EFI" "$sector_size")"
  root_s="$(mib_to_sectors "$PART_SIZE_ROOT" "$sector_size")"
  var_s="$(mib_to_sectors "$PART_SIZE_VAR" "$sector_size")"
  min_home_sectors="$(mib_to_sectors "$MIN_HOME_MIB" "$sector_size")"
  fixed_sectors=$(( esp_s + 2*efi_s + 2*root_s + 2*var_s ))
  home_sectors=$(( end - cur + 1 - fixed_sectors ))
  (( home_sectors >= min_home_sectors )) || die "Selected gap is too small after alignment."

  readvar SFDISK_SCRIPT <<END_SFDISK
start=$cur, size=$esp_s, name="esp", type=$GUID_ESP
start=$((cur + esp_s)), size=$efi_s, name="efi-A", type=$GUID_EFI
start=$((cur + esp_s + efi_s)), size=$efi_s, name="efi-B", type=$GUID_EFI
start=$((cur + esp_s + 2*efi_s)), size=$root_s, name="rootfs-A", type=$GUID_ROOT
start=$((cur + esp_s + 2*efi_s + root_s)), size=$root_s, name="rootfs-B", type=$GUID_ROOT
start=$((cur + esp_s + 2*efi_s + 2*root_s)), size=$var_s, name="var-A", type=$GUID_VAR
start=$((cur + esp_s + 2*efi_s + 2*root_s + var_s)), size=$var_s, name="var-B", type=$GUID_VAR
start=$((cur + esp_s + 2*efi_s + 2*root_s + 2*var_s)), size=$home_sectors, name="home", type=$GUID_HOME
END_SFDISK

  echo
  echo "Partition creation plan for $DISK:"
  echo "$SFDISK_SCRIPT"
  echo

  if (( DRY_RUN == 1 )); then
    warn "Dry-run mode: not writing partition table."
    return 0
  fi

  cmd sfdisk --append "$DISK" <<<"$SFDISK_SCRIPT"
  cmd partprobe "$DISK" || true
  cmd udevadm settle
  sleep 2
  discover_fs_partitions
}

format_and_image_steamos() {
  if (( DRY_RUN == 1 )); then
    warn "Dry-run mode: not formatting or imaging."
    return 0
  fi

  local rootdevice
  rootdevice="$(findmnt -n -o source /)"
  [[ -n "$rootdevice" && -e "$rootdevice" ]] || die "Could not find recovery root device."

  info "Creating var partitions"
  fmt_ext4 var "$(diskpart "$FS_VAR_A")"
  fmt_ext4 var "$(diskpart "$FS_VAR_B")"

  info "Creating boot partitions"
  fmt_fat32 esp "$(diskpart "$FS_ESP")"
  fmt_fat32 efi "$(diskpart "$FS_EFI_A")"
  fmt_fat32 efi "$(diskpart "$FS_EFI_B")"

  info "Creating home partition"
  cmd mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart "$FS_HOME")"
  cmd tune2fs -m 0 "$(diskpart "$FS_HOME")"

  if [[ "$SKIP_JUPITER_UPDATES" != 1 ]]; then
    warn "Jupiter BIOS/controller update steps are not implemented in this safer script."
  fi

  info "Freezing recovery rootfs"
  unfreeze() { fsfreeze -u / || true; }
  trap 'unfreeze; cleanup_extra_mounts' EXIT
  cmd fsfreeze -f /

  info "Imaging OS partition A"
  imageroot "$rootdevice" "$(diskpart "$FS_ROOT_A")"

  info "Imaging OS partition B"
  imageroot "$rootdevice" "$(diskpart "$FS_ROOT_B")"

  info "Finalizing boot configurations"
  finalize_part A
  finalize_part B

  info "Finalizing EFI system partition"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable
}

confirm_danger() {
  echo
  warn "This will create and format SteamOS partitions in the selected free space."
  warn "Existing partitions should not be deleted, but partitioning is always risky."
  echo
  print_disk_tree "$DISK"
  echo
  echo "Selected free region on $DISK: start=${SELECTED_START}s end=${SELECTED_END}s"
  echo "Approx size: $(sector_to_mib_floor "$SELECTED_SIZE" "$(blockdev --getss "$DISK")") MiB"
  echo

  local phrase="INSTALL STEAMOS IN FREE SPACE"
  echo "To continue, type exactly: $phrase"
  read -r -p "> " confirm1
  [[ "$confirm1" == "$phrase" ]] || die "Cancelled."

  echo
  echo "Now type the exact target disk path to confirm: $DISK"
  read -r -p "> " confirm2
  [[ "$confirm2" == "$DISK" ]] || die "Cancelled."
}

run_install() {
  select_choice

  local recovery_disk=""
  recovery_disk="$(root_disk_path || true)"
  [[ -z "$recovery_disk" || "$DISK" != "$recovery_disk" ]] || die "Refusing: target disk is the currently booted root/recovery disk ($DISK)."

  confirm_danger
  create_partitions_in_selected_gap
  format_and_image_steamos

  echo
  info "SteamOS free-space install complete."

  if (( SETUP_BOOT_MENU == 1 )); then
    warn "Attempting boot-menu setup from this environment. If it cannot find the installed SteamOS GRUB directory, reboot into SteamOS and run: sudo $0 boot-menu"
    setup_grub_boot_menu || warn "Boot-menu setup failed. SteamOS install may still be fine; run boot-menu after first boot."
  else
    echo "Reboot, then use your UEFI firmware boot menu if needed."
    echo "After first boot, you can run: sudo $0 boot-menu"
  fi
}

case "${1:-install}" in
  help|-h|--help)
    usage
    ;;
  scan)
    scan_free_spaces
    print_choices || true
    ;;
  scan-windows)
    print_windows_bootmanagers || true
    ;;
  boot-menu)
    shift || true
    if [[ "${1:-}" == "--dry-run" ]]; then
      DRY_RUN=1
    fi
    setup_grub_boot_menu
    ;;
  install)
    shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --setup-boot-menu) SETUP_BOOT_MENU=1 ;;
        *) die "Unknown install option: $1" ;;
      esac
      shift
    done
    run_install
    ;;
  --dry-run)
    DRY_RUN=1
    run_install
    ;;
  *)
    usage
    exit 1
    ;;
esac
