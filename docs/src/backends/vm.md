# microvm.nix VM Backend

The strongest isolation backend. Runs a full NixOS virtual machine — built with
[microvm.nix](https://github.com/microvm-nix/microvm.nix) and executed on QEMU —
with its own kernel and its own filesystem. Claude Code runs in a **tmux
session on the serial console** in your terminal; Chromium renders into an X
server inside the guest, with no window on the host.

## Usage

```bash
# Build
nix build github:jhhuh/claude-code-nix-sandbox#vm

# Run omp in a VM: tmux on the serial console in your terminal (prefix Ctrl-a),
# Chromium headless inside the guest (no host window)
./result/bin/claude-sandbox-vm /path/to/project

# Shell mode
./result/bin/claude-sandbox-vm --shell /path/to/project

# Terminate the project's running VM
./result/bin/claude-sandbox-vm --stop /path/to/project

# Without network (see "Sandbox LAN": the VM still reaches other VMs)
nix build github:jhhuh/claude-code-nix-sandbox#vm-no-network
./result/bin/claude-sandbox-vm /path/to/project
```

## How it works

The backend imports `nix/sandbox-spec.nix` for the canonical package list and
Chrome extension IDs, then evaluates a NixOS configuration that includes
`microvm.nixosModules.microvm`. Everything the guest needs is declared there;
the launcher (`writeShellApplication`) only prepares the host side and runs
`microvm-run` from the generated runner.

- **4 GB RAM, 4 cores** (`microvm.mem` / `microvm.vcpu`)
- **tmpfs root**, so the guest's own filesystem is discarded when it exits
- **The guest's own store image** — an immutable squashfs/erofs disk built by
  microvm.nix, overlaid with a per-project writable layer on a sparse volume.
  The host's store is never exposed (see "Storage model")
- **Serial console on stdio** with the entrypoint wrapped in tmux
- **Xvfb inside the guest** for Chromium; no display device is attached to QEMU
- **Two NICs**: user-mode (slirp) NAT for outbound traffic when `network = true`,
  plus a multicast socket NIC joining the sandbox LAN
- **virtiofs shares** (one `virtiofsd` per share) for the project directory,
  auth, omp state, git config, SSH keys, and metadata

### Console and tmux

The VM has two serial consoles:

| Console | Host side | What runs there |
|---|---|---|
| `ttyS0` | QEMU stdio — your terminal | tmux session (`claude` or `shell`) running the entrypoint |

The microvm machine instantiates a single serial port, and one is all this VM
needs: the agent lives in the tmux session, and a screenshot of its display
lands in the state dir (see "Display" below).

The entrypoint runs **inside tmux on purpose**: detaching (`Ctrl-a d`) leaves
the agent running, and reattaching happens simply by starting the VM again
(the console's `tmux new-session -A` attaches to the existing session). Getty
auto-logs in the `sandbox` user on the console.

**The default agent is omp** (oh-my-pi), which is in the sandbox already;
anything after `--` is passed to it. claude-code is installed as well and can be
started from the session's shell whenever it is wanted.

The tmux config is seeded on the host into the project's state directory
(`tmux.conf`) the first time a project is started, and read from there, so it is
editable and persists. **The prefix is `Ctrl-a`** (`Ctrl-a Ctrl-a` sends a
literal one) — the stock `Ctrl-b` is unbound so it reaches the agent — plus
mouse support, `tmux-256color`, and the same status bar the other backends use.

microvm.nix's `optimize` module narrows the kernel command line to a single
UART; the second console therefore requires `8250.nr_uarts=2`, which the guest
module sets explicitly (and `checks.vm-runner` asserts).

### Display

There is no graphical output on the host: QEMU is started with `-nographic` and
no display device, which is what microvm.nix assumes. Chromium needs an X
server anyway, so the guest runs `Xvfb :0` (1920x1080x24) as the `sandbox` user,
with `-ac` — the same way the manager runs displays for the other backends. The
console session exports `DISPLAY=:0` and waits for the server's socket, since
Xvfb is a plain service and nothing orders the entrypoint after it.

**Chromium needs a writable `$HOME/.config`**, and that directory is a trap
here: the console session symlinks `$HOME/.config` to `/home/sandbox/.config`,
and systemd creates those mount parents — the git/gh shares are mounted inside
— as root. Chromium then dies with `Failed to create headless user data
directory container` and, on the X path, a `Trace/breakpoint trap` core dump
(`mkdir("/home/sandbox/.config/chromium-headless") = EACCES`, found with strace
in the guest). A `systemd.tmpfiles.rules` entry hands the directory to the
sandbox user; after that, `chromium --headless=new --dump-dom` exits 0 and
Chromium on Xvfb renders a real 1920x1080 window (30 KB screenshot against a
390-byte blank-screen baseline). Note that `CHROMIUM_USER_DATA_DIR` does not
help: only the wrapper backends read it, stock Chromium ignores it.

To look at what the browser is showing, take a screenshot *inside* the guest and
leave it in the shared state directory:

```bash
# inside the VM's console:  DISPLAY=:0 import -window root /mnt/state/shot.png
# on the host: ~/.local/state/claude-code-nix-sandbox/projects/<project>-<hash>/shot.png
```

### Storage model

The guest gets **its own copy of the Nix store**, never the host's:

| What | Where it lives | Lifetime |
|---|---|---|
| Guest root filesystem | tmpfs inside the VM | discarded on exit |
| `/nix/store` lower layer | an immutable squashfs/erofs image built by microvm.nix and attached as a read-only disk (`/nix/.ro-store`) | one artifact per build, in the host's Nix store |
| `/nix/store` writes (builds, installs) | `nix-store-overlay.img`, a sparse ext4 volume at `/nix/.rw-store`, used as the overlay's upper layer | persists per project |
| Docker state | `docker.img`, a sparse ext4 volume at `/var/lib/docker` | persists per project |
| `~/.local` (pipx/uv/npm) | the state dir, shared at `/mnt/state` | persists per project |

**The host store is deliberately not shared.** It can hold credentials — secret
values baked into other projects' store paths, fetched sources, private
overlays — and this is the strongest-isolation backend, so the guest must not be
able to read paths belonging to the host or to other sandboxes. Inside the VM,
`/nix/store` contains only this guest's own closure.

That is also where the deduplication comes from: the store image is a single
content-addressed artifact in the host's Nix store, shared by every VM built
from this configuration, and each project only writes its own delta. Both
volumes are sparse — a fresh one is 10 GiB apparent and a few MB on disk
(`ls -lsh`) — so a VM stores only what it actually wrote. Note that a *sparse*
file still counts its full size against the filesystem's free space on some
filesystems; on btrfs/xfs microvm.nix marks them NOCOW, and on tmpfs only
written pages count.

The volumes are named relative to the project's state directory, and microvm.nix
expects to be started from there, so the launcher `cd`s into it before exec'ing
the runner. They are mounted with `noCheck`: the default fstab pass would run
`e2fsck` over a freshly created 10 GiB image (no clean-unmount record yet) —
a full inode-table scan that cost ~1.5 minutes per volume under emulation, and
ext4 replays its journal from an unclean shutdown anyway.

### Sandbox LAN

Every sandbox VM started from the same state root is on **one Ethernet-like
segment** and can reach the others. It is built from a QEMU multicast socket
network: each VM's second NIC is a UDP socket joined to a group derived from the
state root, and QEMU turns frames into datagrams (with `IP_MULTICAST_LOOP` set,
so several VMs on one host do see each other). This is the only unprivileged way
to put VMs on a common L2 — tap and bridge interfaces need `CAP_NET_ADMIN`, which
would make `claude-sandbox-vm` require root.

- Each project gets a stable address in `10.76.<state root>.0/24`, allocated
  once (atomically, via `mkdir` under `$state_root/lan/`) and recorded in
  `$state_root/projects/<project>/lan_ip`; the MAC is derived from it, so it is
  unique per VM and unchanged across restarts.
- `$state_root/lan/<address>/project` maps an address back to a project, which
  is how you find a peer's address from the host.
- The address is printed to the agent as part of its sandbox notice, so Claude
  Code knows its own.
- **The host is not a member of the segment.** Reaching a guest from the host
  needs a tap or bridge (root), or a QEMU port forward for a specific port.
- `vm-no-network` removes the NAT NIC only; VMs still reach each other on the
  LAN, they just have no route off the host.
- Different users (different state roots) get different segments, so their
  `10.76.x.x` addresses cannot collide.

### virtiofs shares

Each directory is exported by its own `virtiofsd` instance — one vhost-user
socket per tag, created in the per-launch metadata dir so any number of VMs can
run concurrently without colliding — and attached to the guest as a
`vhost-user-fs-pci` device. The shared guest RAM vhost-user requires is a
`memory-backend-memfd` object declared in the guest config, because this backend
declares no `microvm.shares` for microvm.nix to derive one from.

| Mount point | Tag | Mode | Description |
|---|---|---|---|
| `/project` | `project_share` | Read-write | Project directory |
| `/home/sandbox/.claude` | `claude_auth` | Read-write, nofail | Auth persistence |
| `/home/sandbox/.omp` | `omp_auth` | Read-write, nofail | omp config + auth |
| `/home/sandbox/.config/git` | `git_config_dir` | Read-only, nofail | Git config directory |
| `/home/sandbox/.config/gh` | `gh_config_dir` | Read-only, nofail | GitHub CLI config |
| `/home/sandbox/.ssh` | `ssh_dir` | Read-only, nofail | SSH keys |
| `/mnt/meta` | `claude_meta` | Read-only | Entrypoint, API key, LAN identity |
| `/mnt/state` | `state_dir` | Read-write, nofail | Per-project state (`~/.local`, screenshots) |

Every one of these has a source that only exists when the launcher runs (the
project directory, the user's home, a per-launch metadata dir), so the launcher
serves them with its own `virtiofsd` processes and passes the matching QEMU
arguments through microvm.nix's `extraArgsScript`. The guest declares the mounts
in `fileSystems`.

**Why virtiofs and not 9p:** every omp database under `~/.omp` is WAL-mode
SQLite, and WAL's wal-index needs a shared `mmap` of the `-shm` file. 9p cannot
mmap shared files, so omp died at startup with `SQLITE_IOERR_SHMMAP` (see
[can1357/oh-my-pi#9082](https://github.com/can1357/oh-my-pi/issues/9082) for the
WAL-on-network-filesystem background). `virtiofsd` serves mmap and `fcntl`
byte-range locks through to the host kernel — the all-processes-on-one-host
access pattern WAL is defined for. Multiple concurrent VMs sharing `~/.omp` stay
coherent for the same reason: their locks serialize in the single host kernel.

`~/.gitconfig` is a file, so no directory share can export it — it is copied
through the meta dir instead (see Metadata passing).

### Memory: what is deduplicated, and what cannot be

Three things are worth separating here, because only two of them work.

**1. The store is shared and deduplicated.** One immutable image per build in
the host's Nix store, sparse per-project overlays on top (see "Storage model").
The host page cache for that image is shared by every VM, and a 4 GiB guest only
allocates host memory for pages it actually touches (a memfd is lazily
populated).

**2. In-guest KSM was tried, measured inert, and is not enabled.** KSM only
merges *anonymous pages a process has explicitly marked* (`madvise(MADV_MERGEABLE)`
or `prctl(PR_SET_MEMORY_MERGE)`); page-cache and file pages are never
candidates, and nothing in a stock guest — Chromium, the Node runtime, glibc —
marks anything. Measured in the guest: 120 MiB of byte-identical private
buffers across three processes merged to `pages_shared: 0`, and even with
`madvise`-marked VMAs registered for minutes, `pages_scanned` stayed 0 (the
guest kernel's ksmd never scanned at all, though `/sys/kernel/mm/ksm/run` was
1). A `hardware.ksm` knob here would have been a placebo, so it was removed.

**3. Host-side KSM over these VMs' RAM is impossible, structurally.** Each VM's
RAM is a *shared* memfd, because vhost-user virtiofs requires shared memory —
and the kernel **ignores `MADV_MERGEABLE` on shared mappings** (`mm/madvise.c`:
`kSM_madvise` returns early for `VM_SHARED | VM_MAYSHARE`). Measured: the 4 GiB
mapping's `VmFlags` contain no `mg`, with `mem-merge=on`, with `merge=on` on the
memory backend, or with both. No transport escapes this: a host-visible
directory that supports SQLite (shared `mmap` + `fcntl` locks, across both the
host's and the guest's processes) *requires* virtiofs, virtiofs *requires*
shared memory, and shared memory cannot be merged. 9p keeps RAM private but
cannot serve the shared mmap that any SQLite WAL database needs — including a
project's own — and network/FUSE transports break WAL's single-kernel
assumption. So `mem-merge=on` is kept and asserted (it is the correct request,
and it is what would make a *private*-RAM VM mergeable), but it is inert here by
construction.

**Host memory is instead reclaimed with balloon free-page reporting**
(`microvm.balloon`): the guest reports pages it has freed, and the host drops
them; `deflate-on-oom` gives memory back when the host is under pressure. QEMU
accepts this alongside vhost-user-fs devices (verified), which is what makes it
usable here.

There is a second reason not to fight for host-side merging: **KSM is a
side channel across trust domains.** It lets one domain test hypotheses about
another's memory by timing whether a page it wrote got merged, which is why
hypervisors offer a per-guest opt-out and why hardening guides treat host KSM as
a trade of isolation for memory. In this project the VM *is* the isolation
boundary, so merging RAM across guests is a trade not worth making — the
structural block is convenient as well as unavoidable. In-guest KSM does not
cross that boundary.

If RAM merging ever has to win over host sharing, the only consistent option is
a VM with **no shared directories at all** — guest-local storage plus a
copy/sync step for the project. That is a different product decision, not a
flag.

### Performance

The guest is tuned for speed rather than for defence in depth *inside* the
sandbox — the isolation boundary is the hypervisor, and everything running in
the guest is untrusted by construction:

- **Latest stable kernel** (`linuxPackages_latest`), because this backend only
  ever runs current NixOS.
- **`mitigations=off`**, `nowatchdog`, `nmi_watchdog=0`, `random.trust_cpu=on`,
  `audit=0`, `loglevel=3`. The first is the biggest CPU win available and the
  one real tradeoff: it removes spectre/meltdown mitigations from the guest
  kernel, so code running inside the sandbox gets an easier target against the
  guest kernel (not against the host). Drop it from `boot.kernelParams` if that
  matters more than throughput.
- **Kernel-side defaults for this workload**: BBR + `fq` on the NAT link,
  inotify watches raised for editors/browsers/watchers, `fs.file-max` and
  `vm.max_map_count` raised for chromium and docker, `vm.swappiness = 1`, and
  lazy writeback ratios (there is no swap here and the root filesystem is
  tmpfs).
- `microvm.optimize` (systemd initrd, networkd, no
  `switch-to-configuration`), a narrow initrd, and volume mounts without
  `e2fsck` — see "Boot time and CPU overhead" below.

### Boot time and CPU overhead

Two things dominate, both measured with this backend:

- **With KVM** (required — see below), boot is seconds and an idle VM costs
  almost nothing. The guest is otherwise deliberately small: `microvm.optimize`
  is on (systemd initrd, networkd, no `switch-to-configuration`), the initrd
  carries no default module set
  (`boot.initrd.includeDefaultModules = false` — only virtio hardware exists
  here), and the store volumes skip `e2fsck`. Measured *under TCG* on this
  machine, the previous q35 backend reached multi-user in 1m19s — and the
  microvm machine type has no bootable TCG configuration that fits this
  guest's device count (see "Requirements"), which is why KVM is a hard
  requirement now.
- **KVM is required.** The guest runs on the `microvm` machine type — no
  display device, no PCI, every device on virtio-mmio, upstream-default machine
  options (`pit=off` et al). Without kvm-clock that machine has no workable
  timer under TCG emulation and stalls before userspace; this was measured
  across pit/pic/acpi combinations, so there is no TCG fallback. The launcher
  fails fast with a clear message when `/dev/kvm` is missing, and the
  **`sandbox-kvm`** package is a bubblewrap sandbox that binds `/dev/kvm`
  through, so the VM backend can run (nested) from inside a sandbox.
  `checks.vm-runner` guards the machine string and the mmio device types.

Docker is the single most expensive guest service to start (it is in the
package set for parity with the previous backend); dropping
`virtualisation.docker.enable` in `extraModules` gives the fastest boot.

### Metadata passing

The entrypoint command, API key, GitHub token, LAN identity, and locale settings
are written to a temporary directory on the host and shared via virtiofs as
`/mnt/meta`. The VM reads these files during shell init:

- `/mnt/meta/entrypoint` — command to run (claude or bash)
- `/mnt/meta/tmux_session` — tmux session name to create or attach (`claude`/`shell`)
- `/mnt/meta/lan_ip`, `/mnt/meta/lan_mac` — sandbox LAN address and NIC MAC
- `/mnt/meta/apikey` — Anthropic API key
- `/mnt/meta/host_home` — host user's home path (for path reconstruction)
- `/mnt/meta/host_project` — host project path (for bind-mount)
- `/mnt/meta/claude.json` — Claude config file
- `/mnt/meta/gh_token` — GitHub token (when `--gh-token` is used)
- `/mnt/meta/lang` — LANG locale setting
- `/mnt/meta/lc_all` — LC_ALL locale setting

### Passing extra QEMU flags

`QEMU_OPTS` is appended to the arguments the launcher composes, after
microvm.nix's own:

```bash
QEMU_OPTS="-d int" ./result/bin/claude-sandbox-vm /path/to/project
```

microvm.nix also gives the VM a QMP socket at `<state dir>/qmp.sock`, which is
useful for inspecting a running VM:

```bash
socat - UNIX-CONNECT:~/.local/state/claude-code-nix-sandbox/projects/<project>-<hash>/qmp.sock
```

## Nix parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `network` | bool | `true` | Attach the user-mode (NAT) NIC |
| `extraModules` | list of NixOS modules | `[]` | Extra NixOS config for the guest |
| `microvm` | flake | (required) | The microvm.nix flake (provides `nixosModules.microvm`) |
| `nixos` | function | (required) | NixOS evaluator |

## Customization example

```nix
pkgs.callPackage ./nix/backends/vm.nix {
  inherit microvm;              # the microvm.nix flake input
  nixos = args: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = args.imports;
  };
  extraModules = [{
    microvm.mem = 8192;
    microvm.vcpu = 8;
    # On a KVM host that wants the literal host CPU instead of `max,-sgx`:
    microvm.cpu = "host,+x2apic,-sgx";
    environment.systemPackages = with pkgs; [ python3 ];
  }];
}
```

## Requirements

- **KVM is required.** The `microvm` machine type has no workable timer under
  TCG emulation: without kvm-clock, every `acpi=on` timer combination stalls
  the kernel before userspace, and the `acpi=off` escape hatch is a dead end —
  without ACPI the machine instantiates only 8 virtio-mmio transports, and
  this guest needs ~15 (measured: "A 'virtio-bus' bus was found but is full"
  on the third runtime share). So there is no software-emulation fallback; the
  launcher exits with a clear error when `/dev/kvm` is missing, and the
  **`sandbox-kvm`** package is a bubblewrap sandbox that binds `/dev/kvm`
  through, so the VM backend can run (nested) from inside a sandbox. The
  guest CPU is a named model (`max,-sgx`) because microvm.nix's default
  (`-cpu host` plus `-enable-kvm`) makes QEMU exit when KVM is missing.
- `virtiofsd` runs as the invoking user and exports the project directory and
  the user's home directories; it needs unprivileged user namespaces (its
  default sandbox), which NixOS allows.
- The guest store image is built once per configuration (a few minutes, cached
  in the Nix store), not per VM.
