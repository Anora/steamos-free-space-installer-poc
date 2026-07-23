# Safety Checks

Before running the install step, always confirm the disk layout manually.

## Required checks

Run:

```bash
lsblk -f
```

Also run the script scan mode:

```bash
sudo ./scripts/steamos_free_space_installer_v2.sh scan
```

Then run dry-run mode:

```bash
sudo ./scripts/steamos_free_space_installer_v2.sh install --dry-run
```

Do not continue unless the dry-run output shows the exact disk and free-space region you expect.

## Important warnings

Do not assume your disk is `/dev/nvme0n1`.

Linux device names can change between boots. A drive that appears as `/dev/nvme0n1` during one boot may appear as `/dev/nvme2n1` during another boot.

If Windows uses BitLocker or device encryption, save the recovery key before changing partitions or boot settings.

If the script shows the wrong disk, the wrong free-space region, or anything you do not understand, stop.

## Recommended flow

1. Back up important files.
2. Save BitLocker/device encryption recovery keys.
3. Create unallocated space using Windows Disk Management or another trusted partition tool.
4. Boot SteamOS recovery.
5. Run `lsblk -f`.
6. Run script scan mode.
7. Run script dry-run mode.
8. Confirm the exact target.
9. Install only after confirming.
10. Test SteamOS boot.
11. Test Windows boot.
12. Only then configure the optional boot menu.
