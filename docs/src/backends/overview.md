# Sandbox Backends

All three backends share a common pattern: they are `callPackage`-able Nix functions that produce `writeShellApplication` derivations. Each accepts `network` (bool) and backend-specific customization options.

## Comparison

| Resource | Bubblewrap | Container | VM |
|---|---|---|---|
| Project directory | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (virtiofs) |
| `~/.claude` | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (virtiofs) |
| `~/.gitconfig`, `~/.ssh` | Read-only (bind-mount) | Read-only (bind-mount) | Read-only (virtiofs) |
| `/nix/store` | Read-only | Read-only | Host store + writable overlay |
| `/home` | Isolated (tmpfs) | Isolated | Separate filesystem |
| Network | Shared by default | Shared by default | NAT + sandbox LAN |
| Display | Host X11/Wayland | Host X11/Wayland | Headless (Xvfb in the VM) |
| Audio | PipeWire/PulseAudio | PipeWire/PulseAudio | Isolated |
| GPU (DRI) | Forwarded | Forwarded | None (software rendering) |
| D-Bus | Forwarded | Forwarded | Isolated |
| SSH agent | Forwarded | Forwarded | Isolated |
| Nix commands | Via daemon | Via daemon | Local store |
| GitHub CLI config | Forwarded | Forwarded | Forwarded (virtiofs) |
| Locale | Forwarded | Forwarded | Forwarded (meta) |
| Kernel | Shared | Shared | Separate |

## Choosing a backend

- **Bubblewrap** — fastest startup, least overhead, good for day-to-day use. Shares the host kernel and network by default. Requires user namespace support.
- **Container** — stronger isolation with separate PID/mount/IPC namespaces. Requires root. Good when you need namespace-level isolation without the overhead of a VM.
- **VM** — strongest isolation with a separate kernel. Best for untrusted workloads. Built with microvm.nix on the `microvm` machine type: the console is a tmux session, Chromium renders into an Xvfb display inside the guest (no window on the host), and all VMs on a host share a sandbox LAN so they can reach each other. Requires KVM (`/dev/kvm`); use `sandbox-kvm` to run it from inside a sandbox.

## Common flags

All backends accept:

```
[--shell] [--gh-token] <project-dir> [claude args...]
```

- `--shell` — drop into bash instead of launching Claude Code (in the VM: a tmux session with bash)
- `--gh-token` — forward `GH_TOKEN`/`GITHUB_TOKEN` env vars into the sandbox
- `--stop` — (VM only) terminate the project's running VM over QMP
- `<project-dir>` — the directory to mount read-write inside the sandbox
- Additional arguments after the project directory are passed to `claude`
