# vivid-unit-os
# Vivid Unit OS Build System

An open build system for generating a Debian-based operating system for **Vivid Unit** devices.

This project aims to replace the previous Rockchip SDK-based workflow with a cleaner, more maintainable, and more upstream-oriented build system based on:

- mainline-friendly components where practical
- a clean Debian rootfs built with `mmdebstrap`
- a modern Linux kernel
- a reproducible board-oriented build layout

The long-term goal is to minimize vendor-specific dependencies and make the system easier to audit, understand, and maintain.

## Project Status

This repository is **work in progress**.

The current build system already replaces large parts of the old RKSDK-based workflow, but some vendor-provided binary components are still required for a working image on current Vivid Unit hardware.

These remaining binary blobs are treated as **third-party components** and are **not covered by the main repository license** unless explicitly stated otherwise.

## Scope

This repository is intended to provide:

- board configuration
- build scripts
- patches
- overlays
- packaging logic
- image assembly logic

## Current Technical Direction

Compared with the older SDK-based workflow, the current direction is:

- build a clean Debian rootfs with `mmdebstrap`
- use a modern kernel
- keep the repository small and focused
- gradually remove or replace vendor-specific binary dependencies where technically possible

At the time of writing, the final image build still requires a small number of third-party firmware / boot-chain binaries for the Vivid Unit platform.

## Repository Layout

Typical top-level structure:

- `boards/` — board-specific manifests, DTS files, firmware, hooks, overlays
- `kernel/` — kernel configs and patches
- `uboot/` — U-Boot configs, patches and overlays
- `rootfs/` — rootfs package lists, overlays and hooks
- `scripts/` — build orchestration

Build outputs, fetched source trees and caches are kept under `out/`.

## Typical Build Flow

A typical build flow looks like this:

```bash
./vuos uboot vivid-unit
./vuos kernel vivid-unit
sudo ./vuos rootfs vivid-unit
sudo ./vuos pack vivid-unit
```

Alternatively you may build everything with just one command:
```bash
sudo ./vuos build vivid-unit
```
The exact workflow may evolve as the project is refined.

## Third-Party Binary Blobs
This repository currently includes a small number of third-party binary blobs that are still required for the Vivid Unit platform. These files come from the historical vendor-based workflow, are kept only as a practical transitional measure, and are not covered by the main repository license unless explicitly stated otherwise. The main license applies to the build system itself; third-party blobs remain subject to their own origin and terms. This project does not claim that all such components have already been replaced by clean upstream alternatives, and they will be removed or replaced over time whenever technically feasible.

## Design Philosophy
This project prefers:
- explicit build logic over hidden SDK magic
- reproducible outputs over ad-hoc manual steps
- upstream-friendly changes where practical
- board-specific customization without carrying an entire vendor SDK
- honest documentation of technical and licensing limitations

## Main License
Unless otherwise stated, original project code and documentation in this repository are licensed under the terms of the license provided in:
- GPL-2.0 license

Third-party binary blobs and other excluded files are not automatically covered by that license.

## Disclaimer
This project is provided as is, without warranty.
This repository includes work intended for embedded hardware bring-up and system image generation. Use it at your own risk.
The project is not affiliated with or endorsed by Rockchip, Broadcom, Debian, or any other third-party vendor mentioned in this repository.
