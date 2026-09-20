# VM virtiofs shares for SQLite WAL databases

## Why not 9p

omp keeps every persistent database under `~/.omp` (`agent.db`,
`history.db`, `models.db`) in SQLite WAL mode — each open sets
`PRAGMA journal_mode=WAL`, so the files have live `-wal` and `-shm`
companions. WAL's wal-index is a shared `mmap(MAP_SHARED)` of the `-shm`
file plus `fcntl` byte-range locks. 9p (virtio-9p) cannot serve that mmap,
so omp inside the VM died at startup, at the first query after open
(`#ensureAuthCredentialRefreshLeasesTable`):

    SQLiteError: Database ".../agent.db": disk I/O error
        code: "SQLITE_IOERR_SHMMAP"

## Why virtiofs works

`virtiofsd` maps guest requests onto host syscalls: shared-file `mmap`
works, and `fcntl` locks land in the **host kernel**. SQLite's contract for
WAL is "all processes using a database must be on the same host computer"
(sqlite.org/wal.html) — every VM's omp plus the host's own omp now
serialize through that one kernel, which is exactly the supported access
pattern (the cross-instance lease coordination in `agent.db` exists for
precisely this). Multiple concurrent VMs sharing `~/.omp` are safe for the
same reason: each VM runs its OWN virtiofsd, but POSIX record locks
conflict across all host processes regardless of which daemon relays them.

Background: can1357/oh-my-pi#9082 — WAL over a shared network filesystem
corrupts silently (categorically: cross-host shm is impossible; rollback
journal modes are only conditionally safe and depend on working byte-range
locks). virtiofs is the strongest fs-level answer for VMs on one host.

## Wiring (`nix/backends/vm.nix`, microvm.nix backend)

The backend splits shares by **when their source becomes known**, which is
what decides the mechanism:

- **Build-time source** — the host store (`builtins.storeDir`). Declared as a
  `microvm.shares` entry, so microvm.nix generates the guest mount *and* the
  QEMU device, and (because `writableStoreOverlay` is set) the overlay wiring
  for `/nix/store`. Its source is read from a store-path file by microvm.nix's
  own daemon tooling, so it cannot be a runtime value.
- **Launch-time source** — the project directory, the user's home
  directories, and the per-launch metadata dir. These get their guest mount
  from a plain `fileSystems."<mount>"` entry with `fsType = "virtiofs"` and
  `device = <tag>`, and their QEMU side from the launcher, which passes
  `-chardev socket` + `-device vhost-user-fs-pci` through
  `microvm.extraArgsScript` (the supported runtime hook — `microvm.shares` is
  evaluated at build time and cannot express them).

Host side (launcher):

- One `virtiofsd --socket-path <sock> --shared-dir <dir> [--readonly |
  --writeback]` per share, started *before* `microvm-run`.
- Runtime-share sockets live in the per-launch `mktemp -d` metadata dir: a
  unix socket path must be shorter than `SUN_LEN` (108), and the state dir
  nests arbitrarily deep. The EXIT trap kills the daemons and removes them.
- The `ro-store` socket must sit at exactly the path declared in
  `microvm.shares` (`virtiofsd-ro-store.sock`, relative), because microvm.nix
  emits that path and the runner is started from the state dir (it resolves
  relative to the runner's cwd). Do not put it in the metadata dir.
- Nothing else: microvm.nix already provides the shared guest RAM that
  vhost-user requires (`-object memory-backend-memfd,id=mem,size=...M,share=on
  -numa node,memdev=mem`) *because* a share is declared. Adding a second
  `-object memory-backend-memfd` would collide on the id.
- `start_vfsd` waits for the socket to appear and dumps
  `$state_dir/virtiofsd-<tag>.log` on failure, so a dead daemon surfaces as
  its own error instead of a cryptic QEMU chardev error.

## Gotchas

- **`extraArgsScript` output is word-split**, never evaluated: no quoting can
  survive in it, so every path passed that way must be space-free. Paths under
  `/tmp` (the metadata dir) and the state dir qualify — `stateDirSnippet`
  mangles whitespace out of the project name, and `XDG_STATE_HOME`/`$HOME`
  would have to contain spaces to break it.
- Read-only shares are enforced twice: `--readonly` on the daemon (host side,
  like 9p's `readonly=on`) and `ro` in the guest mount options.
- virtiofsd exports directories only — single files (`~/.gitconfig`,
  `~/.omp/agent/config.yml`) still ride the meta dir / host-side seeding.
- Ownership passes through (no id mapping): host uid 1000 ↔ guest `sandbox`
  uid 1000 line up; keep it that way.
- virtiofsd's default sandbox is `namespace` (unprivileged user namespaces;
  NixOS allows by default). Upstream store-daemon setups use `--sandbox=none`
  because they export `/nix/store`; ours keeps the default and works, because
  the directory itself is world-readable.
- If a host disables unprivileged user namespaces, virtiofsd fails to start;
  the launcher surfaces `virtiofsd-<tag>.log`.
- Escape hatch if a deployment wants per-VM omp isolation instead of a
  shared DB: `PI_CONFIG_DIR` / `PI_CODING_AGENT_DIR` (omp `dirs.ts`) point
  omp's state at VM-local storage, or `omp auth-broker` centralizes
  credentials (omp#9082 remedies).

## References

- `nix/backends/vm.nix` — implementation
- `nix/sandbox-spec.nix` — `ompConfigSnippet` (host-side config seed)
- `artifacts/skills/microvm-nix-cli-vm-integration.md` — the rest of the
  microvm.nix integration (volumes, runtime args, store overlay)
- https://github.com/can1357/oh-my-pi/issues/9082
