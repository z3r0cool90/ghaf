# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Pin the TSC frequency in pKVM protected guests.
#
# On a host without hardware APICv (IA32_VMX_PROCBASED_CTLS2 bits 8/9 and
# PINBASED_CTLS bit 7 clear -- e.g. i5-9300H), every LAPIC access from a
# protected guest traps and is emulated in software. Early TSC calibration
# depends on the APIC timer, fails its self-check, and the guest falls back
# to the jiffies clocksource. SMP bring-up then takes tens of seconds and
# trips the soft-lockup watchdog:
#
#   watchdog: BUG: soft lockup - CPU#1 stuck for 26s! [migration/1:27]
#
# Measured on net-vm: without these params the guest stalls in SMP bring-up
# and never reaches userspace; with them it boots to a login prompt.
#
# tsc_early_khz skips calibration entirely, tsc=reliable stops the watchdog
# from disabling the TSC, no_timer_check skips the IRQ0 routing probe which
# is also unreliable when the APIC is emulated.
_: {
  # Force-load virtio_net. Without hardware APICv the guest boots ~100x
  # slower, and udev's module autoload for the virtio-net PCI device does
  # not always complete before the network units run -- the interface then
  # simply never appears. Loading it unconditionally is cheap and removes
  # the race.
  boot.initrd.availableKernelModules = [ "virtio_net" ];

  boot.kernelParams = [
    "tsc_early_khz=2399992"
    "tsc=reliable"
    "no_timer_check"
    # The virtio-blk probe can exceed systemd's 90s default device
    # timeout when several protected guests boot at once on a host
    # without APICv -- /dev/vda then never appears and the guest
    # drops to an emergency shell. Raise the ceiling; it only costs
    # patience on a slow boot and changes nothing on a fast one.
    "systemd.default_device_timeout_sec=600"
  ];
}
