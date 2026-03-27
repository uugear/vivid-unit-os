# Vendor rkbin inputs for Vivid Unit

Vendor binaries are placed here for building or flashing Vivid Unit OS.

Currently used by the U-Boot stage:

- `rk3399_bl31_v1.36.elf` (preferred BL31)

RAM training data used by U-Boot device tree:

- `rk3399_ddr_666MHz_v1.30.bin`

The normal build flow prefers these board-local files over auto-building TF-A.
For manual TF-A experiments, you can still export `BL31=/path/to/bl31.elf` when running the U-Boot stage.

Flashing Vivid Unit OS image into Vivid Unit will need this loader:

- `rk3399_loader_v1.30.130.bin`
