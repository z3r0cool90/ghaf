# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  pkgs,
  buildLinux,
  isGuest ? false,
  argsOverride ? { },
  ...
}:
let
  variant = if isGuest then "guest" else "host";
  variants = with pkgs.lib.kernel; {
    guest = {
      HYPERVISOR_GUEST = yes;
      PKVM_GUEST = yes;
    };
    host = {
      KVM = yes;
      KVM_INTEL = yes;
      PKVM_INTEL = yes;
      # VMXROOT_MMIO instead of VE_MMIO: on hosts without APICv the LAPIC
      # #VE conversion fails and the VE_MMIO fallback cannot read protected
      # guest memory, so the guest dies at 33ms in native_apic_mem_read.
      # VMXROOT gives the host emulator a hyp-assisted read. See the kernel
      # fixes in z3r0cool90/pKVM-x86-IA (cr3-fix, share-fix) that this needs.
      PKVM_INTEL_VE_MMIO = no;
      PKVM_INTEL_VMXROOT_MMIO = yes;
      PKVM_INTEL_DEBUG = yes;
      PKVM_INTEL_FORCE_PROTECTED_VM = yes;
      PKVM_INTEL_PROTECTED_VM_COREDUMP = yes;
      KSM = pkgs.lib.mkForce no;
      IOMMU_DEFAULT_PASSTHROUGH = yes;
      INTEL_IOMMU = yes;
    };
  };
  kernelVersion = "6.12.87";
  version = "${kernelVersion}-pkvm-${variant}";

  pkvmKernel = buildLinux (
    {
      inherit version;
      modDirVersion = kernelVersion;

      src = pkgs.fetchFromGitHub {
        owner = "z3r0cool90";
        repo = "pKVM-x86-IA";
        rev = "1cb4a40ecfcd";  # z3r0cool90/pKVM-x86-IA: 0477fe43 + cr3-fix + share-fix
        sha256 = "sha256-eeBsaj/k9ldVINzXRFctMRk/+iTz4hS5lQ30gfDS3xo=";
      };
      structuredExtraConfig = variants.${variant};

      extraMeta = {
        platforms = with lib.platforms; lib.intersectLists x86 linux;
      };
    }
    // argsOverride
  );
in
pkvmKernel
