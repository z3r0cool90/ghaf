# pKVM protected guests on hosts without APICv
## Quick start

**First, check whether your machine even needs this.** These changes only apply
to a host *without* hardware APICv:

```bash
sudo modprobe msr
cat /sys/module/kvm_intel/parameters/enable_apicv
```

- `N` → this branch is for you; the VMXROOT setup below applies.
- `Y` → you do **not** need this branch. Use stock ghaf with the default VE_MMIO.

**Build and run** (fresh checkout):

```bash
git clone -b pkvm-non-apicv-fixes https://github.com/z3r0cool90/ghaf.git
cd ghaf

export TMPDIR=/nix/tmp USE_TMPDIR=1
nix build .#nixosConfigurations.vm-debug-pkvm-nogui.config.system.build.vm \
  -o result --cores 2 -j 1

cp "$(readlink -f result/bin/run-ghaf-host-vm)" run.sh
chmod +w run.sh
# no-APICv host: overcommit vCPUs and give the host VM enough RAM
sed -i 's/-m 8192/-m 6656/; s/-smp 4/-smp 8/' run.sh
./run.sh
```

Nothing else needs editing: `package.nix` already points at the kernel fork
(`z3r0cool90/pKVM-x86-IA @ 1cb4a40`, which carries cr3-fix and share-fix) and
selects `PKVM_INTEL_VMXROOT_MMIO`. The kernel is fetched and built automatically.

**If you already have a ghaf checkout**, pull the branch instead of cloning:

```bash
git remote add panos https://github.com/z3r0cool90/ghaf.git
git fetch panos
git checkout panos/pkvm-non-apicv-fixes
```

**Notes on the runtime flags:**

- `-smp 8` on a 4-core host lets the scheduler interleave vCPU and QEMU I/O
  threads; with `-smp 4` the I/O threads starve and `/dev/vda` times out.
- `-m 6656` leaves headroom on an 8 GB box. Four guests want ~5.5 GB; with less,
  expect the largest guest to be OOM-killed.
- Boot is slow on a no-APICv host (every LAPIC access is emulated) — a full boot
  to login for four guests can take 20–40 minutes. This is expected, not a hang.

---

This document explains the `pkvm-non-apicv-fixes` changes: what they fix,
**where each one applies, and where it is not needed**. It covers both this
ghaf branch and the kernel branch it points at.

Kernel side (`z3r0cool90/pKVM-x86-IA`, branch `pkvm-non-apicv-fixes`):

1cb4a40 pkvm: x86: fix off-by-one in share tracking, raise PKVM_MAX_SHARES
8501767 pkvm: x86: fix __get_user_hyp64 calling convention
0477fe43 (base: elmankku/pKVM-x86-IA)


ghaf side (this branch):

b8ecd43d fix(microvm): pin TSC, raise device timeout, force virtio_net
7175ed29 feat(pkvm): use VMXROOT_MMIO on hosts without APICv
5730de9a (base)


## Background

The `package.nix` here points at the kernel branch above and selects
`PKVM_INTEL_VMXROOT_MMIO` instead of the default `VE_MMIO`. That is only
needed on a host **without hardware APICv**.

On such a host every LAPIC access from a protected guest traps and must be
emulated in software. Under VE_MMIO the `#VE` conversion for the LAPIC fails
(`is_ept_violation_convertible()` returns false: no shadow-EPT mapping and the
suppress-#VE bit set), and the fallback host emulator has no way to read
protected guest memory. KVM then injects a `#PF` with `CR2 == guest RIP` and the
guest dies at 33 ms in `native_apic_mem_read`. VMXROOT gives the host emulator a
hyp-assisted read, so it can decode the instruction and finish the emulation.

A host **with** APICv never routes LAPIC accesses into this path — the hardware
services them — so none of this applies there, and it should stay on the default
VE_MMIO.

## Applicability

| Change | Applies to | Not needed when |
|--------|------------|-----------------|
| `cr3-fix` (kernel) | any host on VMXROOT_MMIO | on VE_MMIO |
| `share-fix` (kernel) | the VMXROOT hyp-read path | on VE_MMIO (path never called) |
| VMXROOT config (`package.nix`) | hosts **without** APICv | with APICv (stay on VE_MMIO) |
| `vm-tsc.nix` | guests on hosts without APICv | with APICv |
| `-smp 8 -m 6656` (runtime) | this host, running 4 guests | more cores / RAM |

Notes:

- **cr3-fix** is tied to the MMIO **mode**, not to APICv — it is correct on any
  CPU, but only exercised under VMXROOT. Without it VMXROOT is unusable
  (35 crashes / 3 reboot loops in the control experiment).
- **share-fix** is a genuine logic bug present in every build, but only *reached*
  via `__hyp_read_guest_page()`, which is VMXROOT-only. VE_MMIO builds never call
  it, so it stays dormant there regardless of hardware — an MMIO-mode
  distinction, not an APICv one.
- **VMXROOT config** carries a security tradeoff: the host emulator can read
  protected guest memory through the hypervisor, gated only on page ownership.
  This is a compatibility fallback, not the architectural answer. The correct fix
  is to make VE_MMIO's #VE conversion work for the LAPIC, which keeps the host
  out of guest memory entirely.
- **vm-tsc.nix**: `tsc_early_khz=2399992` is the nominal frequency of the
  i5-9300H this was developed on and is **wrong on any other CPU**. It must be
  derived at build time, or gated on APICv absence, before this is more than a
  local workaround.
- **runtime flags** are not in git; they belong in whatever launches ghaf-host.
  With four guests on 4 physical cores, `-smp 4` starves the QEMU I/O threads and
  `/dev/vda` times out; `-smp 8` lets the scheduler interleave. `cpu-pm=on` was
  tried and made it worse.

## Classifying a machine

```bash
sudo modprobe msr
sudo rdmsr -f 63:32 0x48b      # PROCBASED_CTLS2: bits 8, 9
sudo rdmsr -f 63:32 0x481      # PINBASED_CTLS:   bit 7
cat /sys/module/kvm_intel/parameters/enable_apicv
```

`enable_apicv = Y` → the VMXROOT changes do not apply; use the default VE_MMIO.
`enable_apicv = N` → expect the 33 ms panic on stock code; these changes get past
it.

## Validation scope

Confirmed on **one** machine: Intel Core i5-9300H (Coffee Lake-H, 4C/8T), 8 GB,
Kali (L0) → QEMU → ghaf-host + pKVM (L1) → protected guests (L2).

- `cr3-fix` and `share-fix` are general kernel fixes, correct wherever their path
  runs.
- The VMXROOT switch and `vm-tsc.nix` are conditional on APICv absence. The
  no-APICv failure and these remedies were confirmed on this one part; they are
  *expected* to apply to any CPU lacking full APICv, but that is inference, not a
  second measurement.

Result on the validated machine (automatic boot from systemd, plus the runtime
flags): 4/4 protected guests reach a login prompt, 3/4 have working networking
(ICMP 5–11 ms). The fourth is limited by host RAM, not by a remaining defect.
Before these changes, on stock code, every guest died at 33 ms on the first
LAPIC read.
