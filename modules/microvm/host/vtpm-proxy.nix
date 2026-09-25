# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# vTPM Proxy Module (Host-side)
#
# This module spawns swtpm-proxy services on the host for VMs with vTPM enabled.
# The admin-vm swtpm services are now in modules/microvm/adminvm-features/vtpm-services.nix
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.virtualization.microvm.appvm;

  # Use enabledVms which has derived vtpm values from evaluatedConfig
  vmsWithVtpm = lib.filterAttrs (_name: vm: vm.vtpm.enable && vm.vtpm.runInVM) cfg.enabledVms;
in
lib.mkIf cfg.enable {
  # Spawn a swtpm-proxy on the host for each VM with vtpm enabled
  systemd.services =
    let
      mkSwtpmProxyService = name: cport: {
        description = "swtpm proxy for ${name}";

        # admin-vm is hard-coded to host the vTPM daemons
        script = ''
          ${pkgs.swtpm-proxy-shim}/bin/swtpm-proxy --type vsock \
            --control-port ${toString cport} \
            --control-retry-count 30 \
            /var/lib/microvms/${name}-vm/vtpm.sock \
            ${toString config.ghaf.networking.hosts.admin-vm.cid}
        '';

        serviceConfig = {
          Type = "exec";
          Restart = "always";
          User = "microvm";
          Slice = "system-appvms-${name}.slice";
        };
        wantedBy = [ "microvms.target" ];
        before = [ "microvm@${name}-vm.service" ];
        after = [ "microvm@admin-vm.service" ];
        wants = [ "microvm@admin-vm.service" ];
      };
      # The shim implements the QEMU control protocol and exposes only the
      # control socket.  Crosvm's virtio-tpm speaks the swtpm server protocol
      # directly, so the data channel is bridged separately.
      mkSwtpmDataService = name: cport: {
        description = "swtpm data channel for ${name}";

        script = ''
          exec ${pkgs.socat}/bin/socat \
            UNIX-LISTEN:/var/lib/microvms/${name}-vm/vtpm-data.sock,fork,unlink-early,mode=0600 \
            VSOCK-CONNECT:${toString config.ghaf.networking.hosts.admin-vm.cid}:${toString (cport + 1)}
        '';

        serviceConfig = {
          Type = "exec";
          Restart = "always";
          User = "microvm";
          Slice = "system-appvms-${name}.slice";
        };
        wantedBy = [ "microvms.target" ];
        before = [ "microvm@${name}-vm.service" ];
        after = [ "microvm@admin-vm.service" ];
        wants = [ "microvm@admin-vm.service" ];
      };
    in
    lib.mkMerge [
      (lib.mapAttrs' (
        name: vm:
        lib.attrsets.nameValuePair "swtpm-proxy-${name}" (mkSwtpmProxyService name vm.vtpm.basePort)
      ) vmsWithVtpm)
      (lib.mapAttrs' (
        name: vm:
        lib.attrsets.nameValuePair "swtpm-proxy-data-${name}" (mkSwtpmDataService name vm.vtpm.basePort)
      ) vmsWithVtpm)
    ];

  # Note: Admin-vm swtpm/socat services are now configured via adminvm-features/vtpm-services.nix
  # which is auto-included in adminvm-base when vTPM VMs exist.
}
