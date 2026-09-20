# claude-code-nix-sandbox

> **Warning:** This project is under active development and should be considered unstable. Features may be incomplete, broken, or change without notice. If you choose to run it, you do so at your own risk. There are no guarantees of correctness, security, or fitness for any particular purpose.

Launch sandboxed [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code) sessions with Chromium using Nix.

Claude Code (from [sadjow/claude-code-nix](https://github.com/sadjow/claude-code-nix)) runs inside an isolated sandbox with filesystem isolation, display forwarding, and a Chromium browser. Three backends are available with increasing isolation strength:

| Backend | Isolation | Requires |
|---|---|---|
| [Bubblewrap](https://github.com/containers/bubblewrap) | User namespaces, shared kernel | Unprivileged |
| [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) | Full namespace isolation | Root (sudo) |
| [microvm.nix](https://github.com/microvm-nix/microvm.nix) VM | Separate kernel, hardware virtualization | KVM required |

A remote sandbox manager is also provided: a Rust/Axum daemon with a web dashboard and CLI for managing sandboxes on a server over SSH.

## Web Dashboard

![Dashboard — sandbox list with live screenshots and system metrics](./images/dashboard.png)

![Sandbox detail — live screenshot, Claude metrics, and WebSocket log viewer](./images/sandbox-detail.png)

## Features

- **Pure Nix** — no shell/Python wrappers; all orchestration in Nix
- **Chromium from nixpkgs** — always `pkgs.chromium` inside the sandbox
- **Git/SSH forwarding** — push/pull works inside all backends
- **Nix commands** — `NIX_REMOTE=daemon` forwarding so `nix build` works inside sandboxes
- **Display** — X11, Wayland, GPU acceleration (bubblewrap/container); a headless Xvfb display inside the guest, driven through tmux (VM)
- **Audio forwarding** — PipeWire/PulseAudio (bubblewrap/container)
- **D-Bus session bus proxy** — filtered via `xdg-dbus-proxy` (keyring/Secret Service only, blocks Chromium singleton collisions)
- **Remote management** — web dashboard with live screenshots, real-time log streaming via WebSocket, metrics, and a CLI over SSH

## Quick Start

```bash
# Install both claude-sandbox and claude-code (bundled)
nix profile install github:jhhuh/claude-code-nix-sandbox

# Bubblewrap (unprivileged)
nix run github:jhhuh/claude-code-nix-sandbox#sandbox -- /path/to/project

# systemd-nspawn container (requires sudo)
nix build github:jhhuh/claude-code-nix-sandbox#container
sudo ./result/bin/claude-sandbox-container /path/to/project

# microvm.nix VM (strongest isolation)
nix build github:jhhuh/claude-code-nix-sandbox#vm
./result/bin/claude-sandbox-vm /path/to/project
```

Requires `ANTHROPIC_API_KEY` in your environment, or an existing `~/.claude` login (auto-mounted).

See [Getting Started](./getting-started.md) for full details.
