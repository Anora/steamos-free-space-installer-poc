# Disclaimer

This project is unofficial and is not affiliated with Valve, Steam, Steam Deck, or SteamOS.

This project is alpha-level proof-of-concept work. It is not a polished installer, not an official recovery tool, and not intended for general users who are unfamiliar with Linux disk partitioning.

## Data loss warning

The scripts in this repository can modify disk partition tables and create or format partitions.

If used incorrectly, they can destroy data, break an operating system install, or make a system unbootable.

Before using anything in this repository:

* Back up important data
* Save your Windows BitLocker/device encryption recovery key, if applicable
* Verify your disk layout with `lsblk -f`
* Run scan and dry-run modes before installing
* Do not proceed unless you understand exactly which disk and free-space region will be modified

Do not assume your target disk is `/dev/nvme0n1`. Linux device names can change between boots.

## No warranty

This project is provided as-is, without warranty of any kind.

The author is not responsible for lost data, broken bootloaders, damaged installations, failed updates, hardware incompatibility, or any other issue caused by using or modifying these scripts.

## SteamOS and Valve files

This repository does not claim ownership of SteamOS, Steam, Steam Deck, Valve trademarks, or Valve-provided recovery tools.

The scripts and documentation in this repository are independent, unofficial proof-of-concept work intended for testing and discussion.

## Intended audience

This project is intended for advanced users who understand UEFI booting, GPT partitioning, Linux device naming, SteamOS recovery media, and the risk of destructive disk operations.

If you are unsure what the script output means, do not run the install step.
