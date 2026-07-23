# How It Works

This document explains the general idea behind the SteamOS free-space installer proof of concept.

This is not an official SteamOS installer. It is an experimental shell-script approach for installing SteamOS into existing unallocated/free space on a PC without wiping an existing Windows install.

## Background

The SteamOS recovery environment includes tools for repairing or reinstalling SteamOS.

On a Steam Deck, this makes sense because the recovery flow expects the device layout to match what SteamOS normally uses.

On a desktop or laptop PC, the situation is different. A PC may have:

* Windows already installed
* multiple NVMe or SATA drives
* recovery partitions
* OEM partitions
* Linux partitions
* unallocated/free space
* changing Linux device names between boots

Because of this, a whole-device recovery flow can be dangerous if it does not clearly show what disk will be modified.

## Original issue

The normal SteamOS recovery reimage flow behaves like a full-device install/reimage tool.

The issue this project is trying to explore is:

* the user may only want to use existing unallocated/free space
* the user may want to preserve Windows
* the target drive may not always appear as the same Linux device name
* the recovery UI may not provide a normal PC-style disk/free-space picker

For example, a drive that appears as:

```text
/dev/nvme0n1
```

during one boot may appear as:

```text
/dev/nvme2n1
```

during another boot.

This is why the script avoids trusting a hardcoded device path.

## Main idea

Instead of wiping an entire disk, this proof of concept tries to:

1. scan available disks
2. detect unallocated/free space
3. show the user a list of possible targets
4. require a dry-run before install
5. create the SteamOS partition layout only inside the selected free space
6. leave existing Windows partitions untouched
7. optionally add a Windows Boot Manager entry to SteamOS GRUB

## SteamOS partition layout

SteamOS expects several partitions instead of one simple Linux root partition.

The layout includes:

* `esp`
* `efi-A`
* `efi-B`
* `rootfs-A`
* `rootfs-B`
* `var-A`
* `var-B`
* `home`

This proof of concept creates those partitions inside the selected free-space region.

The exact partition numbers depend on the target disk’s existing layout.

For example, if Windows already uses the first partitions on a drive, the SteamOS partitions may be created after them.

## Scan mode

Scan mode lists possible install locations.

Run:

```bash
sudo bash scripts/steamos_free_space_installer_v2.sh scan
```

The purpose of scan mode is to show what the script sees before anything destructive happens.

Users should compare the scan output with:

```bash
lsblk -f
```

Do not continue if the output does not match the expected disk layout.

## Dry-run mode

Dry-run mode previews what the installer would do.

Run:

```bash
sudo bash scripts/steamos_free_space_installer_v2.sh install --dry-run
```

Dry-run mode should be used before any real install attempt.

The user should confirm:

* the correct disk is selected
* the correct free-space region is selected
* Windows partitions are not selected
* the expected SteamOS partitions would be created
* nothing unexpected would be deleted or formatted

If anything looks wrong, stop.

## Install mode

Install mode performs the actual partition creation and SteamOS setup.

Run only after scan and dry-run have been checked:

```bash
sudo bash scripts/steamos_free_space_installer_v2.sh install
```

This step can modify the disk.

Even though the goal is to use only free space, mistakes can still destroy data. Backups are strongly recommended.

## Boot menu support

After SteamOS has booted successfully at least once, the script can optionally add a Windows Boot Manager entry to SteamOS GRUB.

First scan for Windows:

```bash
sudo bash scripts/steamos_free_space_installer_v2.sh scan-windows
```

Preview the boot menu entry:

```bash
sudo bash scripts/steamos_free_space_installer_v2.sh boot-menu --dry-run
```

Write the boot menu entry:

```bash
sudo bash scripts/steamos_free_space_installer_v2.sh boot-menu
```

This writes a custom GRUB entry to:

```text
/efi/EFI/steamos/custom.cfg
```

It does not directly edit SteamOS’s generated `grub.cfg`.

The Windows entry uses the Windows EFI bootloader path:

```text
/EFI/Microsoft/Boot/bootmgfw.efi
```

## Why use `custom.cfg`?

SteamOS GRUB can load a custom configuration file.

Using `custom.cfg` is safer than directly editing the generated SteamOS GRUB configuration, because generated files may be overwritten by updates or repair tools.

The goal is:

```text
Power on PC
↓
SteamOS GRUB menu
↓
Choose SteamOS or Windows Boot Manager
```

## What this project does not do

This project does not:

* modify Windows Boot Manager
* modify Windows BCD
* guarantee compatibility with every PC
* guarantee compatibility with every SteamOS update
* replace backups
* provide an official Valve-supported install method

## Why this is experimental

This is alpha-level proof-of-concept work.

It was created to test whether SteamOS can be installed into existing free space on a PC in a safer way than wiping an entire drive.

It still needs review, testing, and more safety checks before it should be considered safe for general users.

## Recommended testing approach

A careful test should look like this:

1. Back up important files.
2. Save Windows BitLocker/device encryption recovery keys, if applicable.
3. Create unallocated space using Windows Disk Management or another trusted partition tool.
4. Boot the SteamOS recovery environment.
5. Run `lsblk -f`.
6. Run script scan mode.
7. Run script dry-run mode.
8. Confirm the exact free-space target.
9. Run install mode only if the target is correct.
10. Boot SteamOS.
11. Reboot SteamOS once to confirm it survives restart.
12. Boot Windows from the firmware boot menu.
13. Only after both operating systems boot, configure the optional GRUB boot menu entry.

## Final warning

If you do not understand the disk layout shown by `lsblk -f`, do not run the install step.

This project can destroy data if used incorrectly.
