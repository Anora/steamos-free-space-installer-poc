# SteamOS Free Space Installer POC

Unofficial alpha proof-of-concept scripts for installing SteamOS into existing unallocated/free space on a PC while preserving Windows.

This project is **not affiliated with Valve, Steam, or SteamOS**.

## Status

**Alpha / proof of concept.**

This is not a polished installer. It is a set of shell-script experiments/wrappers intended to test whether the SteamOS recovery process can be made safer for PC dual-boot installs.

This can destroy data if used incorrectly.

## What this tries to do

The official SteamOS recovery environment currently behaves more like a whole-device reimage tool than a normal PC Linux installer.

This project attempts to:

* detect disks and unallocated/free space
* avoid hardcoded `/dev/nvme0n1`
* show the user what disk/free-space region will be used
* require scan and dry-run checks before install
* create SteamOS partitions only inside selected free space
* preserve existing Windows partitions
* optionally add a Windows Boot Manager entry to SteamOS GRUB

## What this does not do

This is **not** an official SteamOS installer.

It does not guarantee safety.

It does not modify Windows Boot Manager or Windows BCD.

It does not replace the need for backups.

It does not make SteamOS officially support your hardware.

## Warning

Before using this, make a backup of anything important.

If Windows uses BitLocker or device encryption, save your recovery key before doing anything.

Do not continue unless you understand the disk layout shown by:

```bash
lsblk -f
```

Do not assume your target disk is `/dev/nvme0n1`. Linux device names can change between boots.

## Intended use case

This is intended for a UEFI PC where:

* Windows is already installed
* there is unallocated/free space on the same drive or another drive
* the user wants SteamOS installed into that free space
* the user does not want to wipe Windows

## Basic usage

Boot into the SteamOS recovery environment.

Run a scan first:

```bash
sudo ./steamos_free_space_installer_v2.sh scan
```

Run a dry-run before installing:

```bash
sudo ./steamos_free_space_installer_v2.sh install --dry-run
```

Only if the dry-run shows the exact free-space target you expect, run:

```bash
sudo ./steamos_free_space_installer_v2.sh install
```

## Optional boot menu setup

After SteamOS has booted successfully at least once, the script can add a Windows entry to SteamOS GRUB.

Scan for Windows:

```bash
sudo ./steamos_free_space_installer_v2.sh scan-windows
```

Preview the GRUB custom entry:

```bash
sudo ./steamos_free_space_installer_v2.sh boot-menu --dry-run
```

Write the custom GRUB entry:

```bash
sudo ./steamos_free_space_installer_v2.sh boot-menu
```

This writes to:

```text
/efi/EFI/steamos/custom.cfg
```

It does not directly edit SteamOS’s generated `grub.cfg`.

## SteamOS partition layout

SteamOS expects several partitions, including:

* ESP
* efi-A
* efi-B
* rootfs-A
* rootfs-B
* var-A
* var-B
* home

This script attempts to create that layout inside the selected free space.

## Recommended safety flow

1. Back up important data.
2. Save your Windows BitLocker/device encryption recovery key, if enabled.
3. Create unallocated space using Windows Disk Management or another trusted partition tool.
4. Boot SteamOS recovery.
5. Run `lsblk -f`.
6. Run the script scan command.
7. Run the dry-run install command.
8. Confirm the exact disk and free-space target.
9. Install only if everything looks correct.
10. After SteamOS boots successfully, test Windows from the firmware boot menu.
11. Only then consider setting up the SteamOS GRUB boot menu entry.

## License

The scripts and documentation in this repository are provided under the license included in this repo.

This project does not claim ownership of SteamOS, Steam, Valve tools, or any Valve-provided recovery files.

## Disclaimer

Use at your own risk.

This project can destroy data if used incorrectly. It is intended for testing and discussion only.
