# Sandbox Backends

All three backends share a common pattern: they are `callPackage`-able Nix functions that produce `writeShellApplication` derivations. Each accepts `network` (bool) and backend-specific customization options.

## Comparison

| Resource | Bubblewrap | Container | VM |
|---|---|---|---|
| Project directory | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (virtiofs) |
| `~/.claude` | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (virtiofs) |
| `~/.gitconfig`, `~/.ssh` | Read-only (bind-mount) | Read-only (bind-mount) | Read-only (virtiofs) |
| `/nix/store` | Read-only | Read-only | Shared from host |
| `/home` | Isolated (tmpfs) | Isolated | Separate filesystem |
| Network | Shared by default | Shared by default | NAT by default |
| Display | Host X11/Wayland | Host X11/Wayland | QEMU window (Xorg) |
| Audio | PipeWire/PulseAudio | PipeWire/PulseAudio | Isolated |
| GPU (DRI) | Forwarded | Forwarded | Virtio VGA |
| D-Bus | Forwarded | Forwarded | Isolated |
| SSH agent | Forwarded | Forwarded | Isolated |
| Nix commands | Via daemon | Via daemon | Local store |
| GitHub CLI config | Forwarded | Forwarded | Forwarded (virtiofs) |
| Locale | Forwarded | Forwarded | Forwarded (meta) |
| Kernel | Shared | Shared | Separate |

## Choosing a backend

- **Bubblewrap** — fastest startup, least overhead, good for day-to-day use. Shares the host kernel and network by default. Requires user namespace support.
- **Container** — stronger isolation with separate PID/mount/IPC namespaces. Requires root. Good when you need namespace-level isolation without the overhead of a VM.
- **VM** — strongest isolation with a separate kernel. Best for untrusted workloads. Requires KVM for reasonable performance. Chromium renders in the QEMU window rather than forwarding to the host display.

## Common flags

All backends accept:

```
[--shell] [--gh-token] <project-dir> [claude args...]
```

- `--shell` — drop into bash instead of launching Claude Code
- `--gh-token` — forward `GH_TOKEN`/`GITHUB_TOKEN` env vars into the sandbox
- `--headless` — (VM only) force `-display none`; the VM backend also falls back to this automatically when no display is available
- `<project-dir>` — the directory to mount read-write inside the sandbox
- Additional arguments after the project directory are passed to `claude`
