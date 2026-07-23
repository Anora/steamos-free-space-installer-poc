#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# SteamOS free-space PC installer proof-of-concept v2.
#
# WARNING:
#   This is experimental. It writes a partition table, formats new
#   partitions, and images SteamOS. Back up important data before using it.
#   Run from the SteamOS recovery environment, not from an installed SteamOS
#   system on the same target disk.

set -euo pipefail
