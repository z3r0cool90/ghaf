# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# VM Target - QEMU VM for development and testing
#
# This target runs GUI on the HOST (not in a gui-vm microvm).
# VMs: netvm, audiovm, adminvm, appvms (media)
#
{
  inputs,
  lib,
  self,
  ...
}:
let
  system = "x86_64-linux";
  buildAttrs = {
    vm = "vm";
    vmware = "vmwareImage";
  };
  formatModules = {
    vm =
      { modulesPath, lib, ... }:
      {
        imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
        virtualisation.diskSize = lib.mkDefault (2 * 1024);
      };
    vmware =
      { modulesPath, ... }:
      {
        imports = [ "${modulesPath}/virtualisation/vmware-image.nix" ];
      };
  };
  vm =
    format: variant: withGraphics:
    let
      profileName = if lib.hasPrefix "release" variant then "release" else "debug";
      hostConfiguration = lib.nixosSystem {
        specialArgs = {
          inherit (self) lib;
          inherit inputs;
        };
        modules = [
          formatModules.${format}
          self.nixosModules.profiles-vm
          self.nixosModules.hardware-x86_64-generic
          self.nixosModules.hardware-x86_64-hypervisor

          (
            { config, pkgs, ... }:
            let
              # Helper for GIVC transport config pointing to host
              inherit (config.networking) hostName;
              hostIpv4 = config.ghaf.networking.hosts.${hostName}.ipv4;

              # GIVC config for netvm - point socket proxy to host
              netvmGivcModule = lib.optionalAttrs withGraphics {
                givc.sysvm = {
                  capabilities = {
                    socketProxy = {
                      enable = true;
                      sockets = lib.mkForce [
                        {
                          transport = {
                            name = hostName;
                            addr = hostIpv4;
                            port = "9010"; # GIVC netvm proxy port
                            protocol = "tcp";
                          };
                          socket = "/tmp/dbusproxy_net.sock"; # D-Bus proxy for NetworkManager
                        }
                      ];
                    };
                  };
                };
              };

              # GIVC config for audiovm - point socket proxy to host
              audiovmGivcModule = lib.optionalAttrs withGraphics {
                givc.sysvm = {
                  capabilities = {
                    socketProxy = {
                      enable = true;
                      sockets = lib.mkForce [
                        {
                          transport = {
                            name = hostName;
                            addr = hostIpv4;
                            port = "9011"; # GIVC audiovm proxy port
                            protocol = "tcp";
                          };
                          socket = "/tmp/dbusproxy_snd.sock"; # D-Bus proxy for PulseAudio/Blueman
                        }
                      ];
                    };
                  };
                };
              };
              # Reference to profile for convenience
              vmProfile = config.ghaf.profiles.vm;

              # Enable pKVM for variants that include "pkvm", only for qemu-vm format
              withPkvm = format == "vm" && lib.hasInfix "pkvm" variant;
            in
            {
              environment.systemPackages = lib.optionals withGraphics [
                pkgs.gnome-calculator
              ];

              ghaf = {
                # Propagate the selected host variant to the system VMs.
                global-config =
                  lib.recursiveUpdate (lib.mapAttrsRecursive (_: v: lib.mkDefault v) lib.ghaf.profiles.${profileName})
                    # nogui variants intentionally disable host GIVC, so guests must not
                    # request GIVC TLS volumes that the host will not generate.
                    { givc.enable = withGraphics; };

                # Enable the VM profile (creates netvmBase, audiovmBase, adminvmBase, mkAppVm)
                profiles.vm.enable = true;

                hardware.x86_64.common.enable = true;
                hardware.tpm2.enable = true;

                # No physical devices to pass through in a nested VM target.
                # With net-vm on crosvm this would otherwise trip the crosvm
                # PCI-passthrough assertion (it needs vhotplug + a control
                # socket). The TPM test needs none of that.
                hardware.passthrough.mode = lib.mkIf withPkvm (lib.mkForce "none");

                microvm-boot.enable = lib.mkForce false;

                virtualization = {
                  pkvm.enable = withPkvm;

                  # TPM passthrough to a protected guest goes through crosvm's
                  # virtio-tpm (--tpm-device); the QEMU path uses -tpmdev and is
                  # wired separately in vm-tpm.nix. net-vm is the VM that holds
                  # the LUKS key, so it is the one that needs the TPM.
                  vmConfig.sysvms.netvm.vmm = lib.mkIf withPkvm "crosvm";

                  microvm-host = {
                    enable = true;
                    networkSupport = true;
                  };

                  # Wire up VM evaluatedConfigs using the profile's bases
                  microvm = {
                    netvm = {
                      enable = true;
                      evaluatedConfig = vmProfile.netvmBase.extendModules {
                        modules = [
                          netvmGivcModule
                        ]
                        ++ lib.ghaf.vm.applyVmConfig {
                          inherit config;
                          vmName = "netvm";
                        };
                      };
                    };

                    audiovm = {
                      enable = true;
                      evaluatedConfig = vmProfile.audiovmBase.extendModules {
                        modules = [
                          audiovmGivcModule
                        ]
                        ++ lib.ghaf.vm.applyVmConfig {
                          inherit config;
                          vmName = "audiovm";
                        };
                      };
                    };

                    adminvm = {
                      enable = true;
                      evaluatedConfig = vmProfile.adminvmBase.extendModules {
                        modules = lib.ghaf.vm.applyVmConfig {
                          inherit config;
                          vmName = "adminvm";
                        };
                      };
                    };

                    # NOTE: GUI runs on host, not in a gui-vm
                    # guivm.enable = withGraphics;

                    # AppVMs - configured inline since reference-appvms uses laptop-x86 profile
                    appvm = {
                      enable = true;
                      vms = {
                        media = {
                          enable = true;
                          # Create evaluatedConfig with waypipe disabled (no guivm)
                          evaluatedConfig = vmProfile.mkAppVm {
                            name = "media";
                            mem = 512;
                            vcpu = 1;
                            borderColor = "#122263"; # Dark blue — security context indicator
                            waypipe.enable = false; # No guivm, so no waypipe
                            applications = [
                              {
                                name = "com.system76.CosmicReader";
                                desktopName = "COSMIC Document Reader";
                                categories = [
                                  "COSMIC"
                                  "Office"
                                  "Viewer"
                                ];
                                packages = [
                                  pkgs.cosmic-reader
                                  pkgs.cosmic-icons
                                ];
                                icon = "com.system76.CosmicReader";
                                exec = "cosmic-reader";
                              }
                            ];
                          };
                        };
                      };
                    };
                  };
                };

                # Add some launchers for host GUI
                graphics.launchers = lib.optionals withGraphics [
                  {
                    name = ".blueman-manager-wrapped";
                    desktopName = "Bluetooth Settings";
                    description = "Manage Bluetooth Devices & Settings";
                    icon = "bluetooth-48";
                    exec = "${pkgs.writeShellScriptBin "bluetooth-settings" ''
                      PULSE_SERVER=audio-vm:${toString config.ghaf.services.audio.server.pulseaudioTcpControlPort} \
                      ${pkgs.blueman}/bin/blueman-manager
                    ''}/bin/bluetooth-settings";
                  }
                ];

                # Add simple login user for testing purposes
                users.managed = [
                  {
                    name = "user";
                    vms = [ "ghaf-host" ];
                    initialPassword = "ghaf";
                    uid = 1000;
                    extraGroups = [
                      "wheel"
                    ];
                  }
                ];

                givc = {
                  # GIVC is enabled only on the host; it is disabled on all other target VMs.
                  # Because of this, access control is not meaningful here. Additionally, the host
                  # enables two GIVC agents (givc-host and givc-gui-vm), which causes an ACL file
                  # path collision that needs to be resolved in GIVC itself.
                  #
                  # TODO: Fix the ACL file collision in GIVC and enable ACL here, even though it
                  # provides no practical benefit in this configuration.

                  accessControl.enable = lib.mkForce false;
                  enable = withGraphics;
                  debug = true;
                  # We enable the gui-vm module as the desktop runs on the host
                  guivm.enable = withGraphics;
                };

                host = {
                  networking.enable = true;
                };

                # Enable all the default UI applications
                profiles = {
                  graphics = {
                    enable = withGraphics;
                  };
                  release.enable = profileName == "release";
                  debug.enable = profileName == "debug";
                };
              };

              # Enable GUI component on host
              givc.sysvm = lib.optionalAttrs withGraphics {
                network = {
                  agent.transport = {
                    name = lib.mkForce "ghaf-host-gui";
                    addr = config.ghaf.networking.hosts.ghaf-host.ipv4;
                    port = lib.mkForce "9002"; # GIVC host GUI transport port
                  };
                };
                capabilities = {
                  services = lib.optionals config.ghaf.gracefulShutdown [
                    "poweroff.target"
                  ];
                  eventProxy.enable = lib.mkForce false;
                };
              };

              # Reorder some GIVC services to ensure proper startup order in host
              systemd.services = lib.optionalAttrs withGraphics {
                givc-key-setup.after = [ "local-fs.target" ];
                givc-user-key-setup.after = [ "givc-key-setup.service" ];
              };

              nixpkgs = {
                hostPlatform.system = system;

                config = {
                  allowUnfree = true;
                  permittedInsecurePackages = [
                    "jitsi-meet-1.0.8043"
                    "qtwebengine-5.15.19"
                  ];
                };

                overlays = [ self.overlays.default ];
              };

              virtualisation = lib.optionalAttrs (format == "vm") {
                graphics = withGraphics;
                useNixStoreImage = true;
                writableStore = true;
                cores = 4;

                # pKVM cannot reuse pages
                memorySize = if withPkvm && withGraphics then 20 * 1024 else 8 * 1024;

                forwardPorts = [
                  {
                    from = "host";
                    host.port = 8022;
                    guest.port = 22;
                  }
                ];
                tpm.enable = true;

                # QEMU options when executing pKVM within KVM
                qemu.options = lib.optionals withPkvm [
                  "-machine q35,mem-merge=off,accel=kvm,kernel-irqchip=split"
                  "-device intel-iommu,aw-bits=48,device-iotlb=on,intremap=on"
                  "-overcommit cpu-pm=off"
                  # Paravirtualizations must be disabled
                  "-cpu host,+kvm-pv-enforce-cpuid,+vmx,+waitpkg,+ssse3,+tsc,+nx,+x2apic,+hypervisor,-kvm-pv-ipi,-kvm-pv-tlb-flush,-kvm-pv-unhalt,-kvm-pv-sched-yield,-kvm-asyncpf-int,-kvm-pv-eoi"
                  "-device e1000,netdev=net0"
                  "-netdev user,id=net0"
                ];
              };
            }
          )
        ];
      };
    in
    {
      inherit hostConfiguration;
      name = "${format}-${variant}";
      package = hostConfiguration.config.system.build.${buildAttrs.${format}};
    };
  targets = [
    (vm "vm" "debug" true)
    (vm "vm" "debug-nogui" false)
    (vm "vm" "debug-pkvm" true)
    (vm "vm" "debug-pkvm-nogui" false)
    (vm "vm" "release" true)
    (vm "vm" "release-pkvm" true)
    # nogui release variant: release profile enables storage encryption, which is
    # what turns on TPM passthrough, without the 20GB the graphics pkvm variant needs.
    (vm "vm" "release-pkvm-nogui" false)
    (vm "vmware" "debug" true)
  ];
in
{
  flake = {
    nixosConfigurations = builtins.listToAttrs (
      map (t: lib.nameValuePair t.name t.hostConfiguration) targets
    );
    packages = {
      x86_64-linux = builtins.listToAttrs (map (t: lib.nameValuePair t.name t.package) targets);
    };
  };
}
