# Recovery Notes

This project modifies partitions and boot configuration. Mistakes can make a system fail to boot.

## If Windows still exists but does not boot automatically

Use the motherboard firmware boot menu.

On many ASUS boards, press `F8` during startup and choose `Windows Boot Manager`.

## If SteamOS boots but Windows is missing from the SteamOS GRUB menu

Boot SteamOS, then run:

```bash
sudo ./scripts/steamos_free_space_installer_v2.sh scan-windows
sudo ./scripts/steamos_free_space_installer_v2.sh boot-menu --dry-run
```

If the dry-run looks correct, run:

```bash
sudo ./scripts/steamos_free_space_installer_v2.sh boot-menu
```

This writes a custom Windows entry to:

```text
/efi/EFI/steamos/custom.cfg
```

## If SteamOS does not boot

Use the motherboard firmware boot menu and choose Windows.

Then review the disk layout from Windows Disk Management or boot back into SteamOS recovery and run:

```bash
lsblk -f
```

Do not run the SteamOS recovery “Wipe Device & Install SteamOS” option unless you intend to wipe the selected target disk.

## If unsure

Stop and ask for help before running any command that writes partitions, formats filesystems, or changes boot entries.
