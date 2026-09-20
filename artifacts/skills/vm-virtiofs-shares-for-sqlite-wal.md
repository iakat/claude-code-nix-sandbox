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

## Wiring (`nix/backends/vm.nix`)

Guest:
- `virtualisation.fileSystems."<mount>"` entries with `fsType = "virtiofs"`
  and `device = <tag>`. NEVER plain `fileSystems` — qemu-vm.nix
  mkVMOverride silently drops it (see
  `vm-9p-runtime-path-fixup-for-session-continuity.md`).
- `boot.kernelModules = [ "virtio_fs" ];`

Host (launcher):
- One `virtiofsd --socket-path <state-dir>/virtiofsd-<tag>.sock
  --shared-dir <dir> [--readonly | --writeback]` per share. Sockets live in
  the per-project state dir so concurrent VMs never collide. The socket
  appearing is the readiness check; the daemon log sits next to it and is
  printed on failure.
- Per share: `-chardev socket,id=charvfs_<tag>,path=<sock> -device
  vhost-user-fs-pci,chardev=charvfs_<tag>,tag=<tag>`.
- NOTHING else: the generated run script (qemu-vm.nix) already provides the
  shared guest RAM that vhost-user requires
  (`-object memory-backend-memfd,id=mem0,size=<memorySize>M,share=on
  -machine memory-backend=mem0`) and its own virtiofsd daemons for
  nix-store/xchg/shared. Do NOT add a second `-machine memory-backend=`.
- The EXIT trap kills the daemons (they only self-exit after QEMU
  disconnects; on launcher failure they must not leak).

## Gotchas

- Read-only shares are enforced twice: `--readonly` on the daemon (host
  side, like 9p's `readonly=on`) and `ro` in the guest mount options.
- virtiofsd exports directories only — single files (`~/.gitconfig`,
  `~/.omp/agent/config.yml`) still ride the meta dir / host-side seeding.
- Ownership passes through (no id mapping): host uid 1000 ↔ guest `sandbox`
  uid 1000 line up; keep it that way.
- virtiofsd's default sandbox is `namespace` (unprivileged user
  namespaces; NixOS allows by default). The upstream store daemons use
  `--sandbox=none` because they export `/nix/store`; ours keep the default.
- If a host disables unprivileged user namespaces, virtiofsd fails to
  start; the launcher surfaces `virtiofsd-<tag>.log`.
- Escape hatch if a deployment wants per-VM omp isolation instead of a
  shared DB: `PI_CONFIG_DIR` / `PI_CODING_AGENT_DIR` (omp `dirs.ts`) point
  omp's state at VM-local storage, or `omp auth-broker` centralizes
  credentials (omp#9082 remedies).

## References

- `nix/backends/vm.nix` — implementation
- `nix/sandbox-spec.nix` — `ompConfigSnippet` (host-side config seed)
- https://github.com/can1357/oh-my-pi/issues/9082
