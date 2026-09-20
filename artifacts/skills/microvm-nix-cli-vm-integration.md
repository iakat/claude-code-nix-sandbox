# Driving microvm.nix from a CLI launcher (no host module)

microvm.nix is built around a **NixOS host** that owns VMs via
`microvm.vms.<name>`: the host module creates `/var/lib/microvms/<name>`,
spawns `virtiofsd`, and starts the runner with `WorkingDirectory` set there.
This project has no such host — `claude-sandbox-vm` is a CLI that evaluates a
guest system, gets `microvm.declaredRunner`, and execs
`$runner/bin/microvm-run` itself. That works, but the seams are everywhere.
Everything below was measured on the real thing.

## Build-time vs launch-time configuration

| microvm.nix option | when its value is resolved | usable for us? |
|---|---|---|
| `microvm.shares.*.source` | build time (written into the runner's `share/`) | only for constant paths |
| `microvm.interfaces.*` | build time | yes (NAT NIC) |
| `microvm.volumes.*.image` | build time, but read at runtime **relative to the runner's cwd** | yes, per-project images |
| `microvm.shares.*.socket` | build time, relative to the runner's cwd | yes, the socket can be served by our own daemon |
| `microvm.extraArgsScript` | **runtime** — output is word-split into the hypervisor's argv | this is the hook for runtime devices |
| `microvm.qemu.extraArgs` | build time, appended last | static devices (memory backend) |

So runtime sources (the user's project dir, `$HOME`, a per-launch metadata dir)
ride `extraArgsScript` plus a matching guest `fileSystems` entry, and the
launcher runs one `virtiofsd` per share itself. Two constraints:

- **`extraArgsScript` output is word-split, never evaluated.** No quoting
  survives, so every path passed that way must be space-free.
- The runner is started from the state dir (`cd "$state_dir"; exec
  $runner/bin/microvm-run`), which is what makes relative volume images and
  relative sockets land per project — mirroring the host module's
  `WorkingDirectory=/var/lib/microvms/<name>`.

## The store: never the host's, and writable on top

- **Never share the host store** (`microvm.shares` with
  `source = builtins.storeDir`): it can hold credentials from other projects.
  Use `storeOnDisk = true` (microvm.nix's default) — the guest gets its own
  immutable erofs image, built once per configuration, and
  `/proc/self/mounts`-level inspection inside the guest shows only its own
  closure (925 entries and none of the host's paths, measured).
- **`writableStoreOverlay` double-mounts.** With it set, microvm.nix marks the
  `/nix/store` overlay `neededForBoot`, nixpkgs prefixes its
  lower/upper/work dirs with `/sysroot` for the initrd, and the same fstab
  entry is consumed again in stage 2 — measured result: *two* `overlay
  /nix/store` mounts, the outer one `ro,nosuid,nodev`, shadowing the writable
  one, so `touch /nix/store/...` failed with EROFS and the overlay could not
  even be remounted (`fsconfig() failed: overlay: No changes allowed in
  reconfigure`).
  **Fix**: leave `writableStoreOverlay = null` (the guest then mounts the store
  image read-only at `/nix/store`, which is all the initrd needs to exec
  `init`), and mount the writable layer yourself:

  ```nix
  systemd.services.nix-store-overlay = {
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];            # so everything in multi-user sees it
    unitConfig.RequiresMountsFor = "/nix/store /nix/.rw-store";
    serviceConfig = {
      Type = "oneshot"; RemainAfterExit = true;
      ExecStartPre = [ "mkdir -p /nix/.ro-store"
                       "mount --bind -o ro /nix/store /nix/.ro-store" ];
      ExecStart = "mount -t overlay overlay -o lowerdir=/nix/.ro-store,upperdir=/nix/.rw-store/store,workdir=/nix/.rw-store/work /nix/store";
      ExecStop = [ "umount /nix/store" "umount /nix/.ro-store" ];
    };
  };
  ```

  The bind is required because with `writableStoreOverlay = null` the image is
  mounted *at* `/nix/store` — using that as the overlay's own lowerdir would
  recurse.
- With `writableStoreOverlay = null`, microvm.nix also does
  `systemd.services.nix-daemon.enable = mkDefault false`, so force it back on
  (`lib.mkForce true`, plus the socket) or `nix build` inside the guest talks
  to no daemon.

## Booting without KVM

microvm.nix targets KVM hosts, and its defaults *fail* on a KVM-less machine:

- **`cpu = null` (default) emits `-cpu host` plus `-enable-kvm`.** Without
  `/dev/kvm` QEMU *exits* ("failed to initialize kvm") instead of falling back.
  Naming a CPU model (`cpu = "max,-sgx"`) drops `-enable-kvm` and leaves the
  accelerator list at `kvm:tcg`, so KVM is used when present and TCG when not.
  Setting `cpu` also switches `microvm.qemu.package` to the full `pkgs.qemu`;
  pin `pkgs.qemu_kvm` back to keep the slim build. `-accel` cannot be layered on
  from outside (`The -accel and "-machine accel=" options are incompatible`).
- **The `microvm` machine type stalls under TCG with its default options, and
  `acpi=off` is not an escape.** Upstream defaults (`acpi=on`, `pit=off`) are
  fine under KVM, but under TCG the kernel hangs before userspace — no
  kvm-clock, and every pit/pic/rtc combination still stalls (measured twice,
  8 minutes each). Switching to `acpi=off` boots TCG *but* caps the machine at
  **8 virtio-mmio transports** (cmdline enumeration), which a real guest with
  several virtiofs shares exhausts immediately ("A 'virtio-bus' bus was found
  but is full"). Conclusion for this backend: the microvm machine requires
  KVM; the launcher fails fast without `/dev/kvm`, and a `sandbox-kvm`
  bubblewrap variant binds the device through for nested use. Use
  `q35` instead only if TCG-without-KVM is a hard requirement.
- The `microvm` machine type also **rejects `-vga`** ("this machine type does
  not use that option; No VGA device has been created"), which is why this
  backend has no display device at all (see the headless skill).

## vhost-user needs shared memory, which rules KSM out

`virtiofs` here is `vhost-user-fs-pci`, and vhost-user is handed guest RAM over
a socket, so guest memory must be a **shared** memfd. microvm.nix emits that
object only when it declared a share itself; with `microvm.shares = []` (which
is the case once the host store is not shared) the launcher's config must
declare it, at exactly `microvm.mem`:

```nix
microvm.qemu.extraArgs = [ "-object" "memory-backend-memfd,id=mem,size=4096M,share=on"
                           "-numa" "node,memdev=mem" ];
```

Consequence, measured: `/proc/<qemu>/smaps` shows **no `mg`** on the 4 GiB
mapping even though `mem-merge=on` is set, because the kernel ignores
`MADV_MERGEABLE` on `VM_SHARED | VM_MAYSHARE` mappings (`mm/madvise.c`
`kSM_madvise`). Adding `merge=on` to the memfd backend does not change it.
Private (non-vhost-user) RAM *is* marked mergeable. So: KSM cannot deduplicate a
virtiofs-based VM's RAM, no matter what the host's `/sys/kernel/mm/ksm/run`
says; the store image is what gets deduplicated instead.

### What to do about RAM instead

Three options, in the order they were tried:

1. **KSM inside the guest — tried, measured inert, removed.** KSM merges only
   anonymous pages the process itself marked with `madvise(MADV_MERGEABLE)`;
   nothing in a stock guest (Chromium, Node, glibc) marks anything. Measured:
   120 MiB of byte-identical private buffers across three guest processes →
   `pages_shared: 0`; with explicitly marked VMAs registered for minutes →
   `pages_scanned: 0` (ksmd never scanned despite `run=1`). Do not ship a
   `hardware.ksm` knob for these guests.
2. **Balloon free-page reporting** (`microvm.balloon = true`, which emits
   `virtio-balloon-*,free-page-reporting=on,deflate-on-oom=on`). The guest
   reports freed pages and the host drops them. Unlike KSM this *does* work with
   vhost-user shared memory: QEMU accepts the device alongside
   `vhost-user-fs-pci` (verified by running the exact argument set).
3. **Give up host-shared directories.** RAM can only be private if no vhost-user
   device exists, and dropping virtiofs costs shared `mmap` + `fcntl` locks —
   i.e. every SQLite WAL database in the guest, including a project's own. 9p
   keeps RAM private but breaks those; network/FUSE transports break WAL's
   single-kernel assumption. So this is a product decision (guest-local storage
   plus copy-in/copy-out), not a transport swap.

## Boot-time knobs that matter

- **Volumes are fsck'd by default.** A freshly created 10 GiB image has no
  clean-unmount record, so the default fstab pass runs a full `e2fsck` over it
  — ~1.5 minutes per volume under TCG, delaying `/var/lib/docker` past
  everything else. Set `fileSystems."<mount>".noCheck = true` for volume mounts
  (ext4 replays its journal anyway).
- **The initrd does not need NixOS's default module set** if the guest is
  virtio-only: `boot.initrd.includeDefaultModules = false`, then name what is
  actually needed (`ext4`, and microvm.nix's own virtio list stays). The
  writable-layer volume is mounted from the initrd, so forgetting `ext4` is a
  hard boot failure.
- **`microvm.optimize` narrows the kernel to one UART** (`8250.nr_uarts=1`), so
  a second serial console needs `boot.kernelParams = lib.mkForce [ ...
  "8250.nr_uarts=2" ]` (mkForce, because microvm appends rather than replaces).
- **A named CPU model is required for TCG** (see above), and the fail-fast
  `-enable-kvm` must not come back.

## Evaluating the guest from a NixOS module

The module path (`nixosModules.default` → `nix/modules/sandbox.nix`) evaluates
the guest systems itself, so it needs two things that only the flake has: the
`microvm` input and the overlays that provide `claude-code`/`omp`. The flake
passes them as module arguments:

```nix
nixosModules.default = { ... }: {
  imports = [ ./nix/modules/sandbox.nix ];
  _module.args.claudeSandbox = { inherit microvm; overlays = [ ... ]; };
};
```

Without that, the guest evaluation silently used plain nixpkgs and would have
failed on the first `pkgs.claude-code` reference — the same class of bug the
overlay-injection skill describes, one level up.

## Checks worth having

Both live in `flake.nix` and both guard silent failures:

- `vm-mounts`: the generated guest fstab has every virtiofs tag, the store image
  at `/nix/store` as erofs, both volumes as ext4, and the overlay unit exists.
- `vm-runner`: the generated `bin/microvm-run` command line contains `q35`,
  `mem-merge=on`, `memory-backend-memfd`, `8250.nr_uarts=2`, `-nographic`, and
  does **not** contain `pit=off`.

## References

- `nix/backends/vm.nix` — the implementation
- `artifacts/skills/vm-virtiofs-shares-for-sqlite-wal.md` — the share wiring
- `artifacts/skills/microvm-nix-headless-vm-xvfb.md` — display
- `artifacts/skills/nixos-qemu-vm-serial-console-setup.md` — consoles
