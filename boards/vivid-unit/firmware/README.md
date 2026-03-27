The build hook will copy it into the target rootfs under /usr/lib/firmware/brcm/
using the compatible names expected by the current btattach + kernel Broadcom
initialization path, including:

  BCM4343A1.hcd
  BCM43430A1.hcd
  BCM43430A1.rockchip,rk3399-vivid-unit.hcd

This firmware is still required by the runtime Bluetooth path.
