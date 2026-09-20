# Getting Started

## Requirements

- **NixOS or Nix with flakes enabled** on Linux
- **User namespaces** for the bubblewrap backend (enabled by default on most distros)
- **X11 or Wayland** display server for bubblewrap/container backends
- **KVM** recommended for the VM backend (`/dev/kvm`); without it the VM runs under software emulation (slow but functional)
- **`ANTHROPIC_API_KEY`** in your environment, or an existing `~/.claude` login (auto-mounted)

## Quick Start

### Install (both sandboxed and un-sandboxed)

The default package bundles `claude-sandbox` (bubblewrap) and `claude` (un-sandboxed) together:

```bash
# Install both binaries
nix profile install github:jhhuh/claude-code-nix-sandbox

# Update to latest
nix profile upgrade claude-code-nix-sandbox --refresh
```

### Bubblewrap (unprivileged)

```bash
# Run Claude Code in a sandbox
nix run github:jhhuh/claude-code-nix-sandbox#sandbox -- /path/to/project

# Run inside tmux (needed for agent teams)
nix run github:jhhuh/claude-code-nix-sandbox#sandbox -- --tmux /path/to/project

# Drop into a shell inside the sandbox
nix run github:jhhuh/claude-code-nix-sandbox#sandbox -- --shell /path/to/project
```

### systemd-nspawn container (requires sudo)

```bash
nix build github:jhhuh/claude-code-nix-sandbox#container

sudo ./result/bin/claude-sandbox-container /path/to/project

# Shell mode
sudo ./result/bin/claude-sandbox-container --shell /path/to/project
```

### microvm.nix VM (strongest isolation)

Claude runs in a tmux session on the serial console in your terminal — the default agent is **omp**, and claude-code is available from the session's shell. Detach with `Ctrl-a d` and the VM keeps running; reattach by starting the VM again (`tmux new-session -A` reattaches). Chromium renders into a headless X server inside the guest; there is no window on the host (screenshot it with `import` from the shared state dir).

```bash
nix build github:jhhuh/claude-code-nix-sandbox#vm

./result/bin/claude-sandbox-vm /path/to/project

# Shell mode (tmux + bash)
./result/bin/claude-sandbox-vm --shell /path/to/project

# Terminate the project's VM
./result/bin/claude-sandbox-vm --stop /path/to/project
```

VMs started from the same host share a private sandbox LAN and can reach each other; the address of this sandbox is printed to Claude at startup and recorded in `~/.local/state/claude-code-nix-sandbox/projects/<project>-<hash>/lan_ip`.

## What gets forwarded

All three backends automatically forward these from your host:

- **`~/.claude`** — auth persistence (read-write)
- **`~/.gitconfig`, `~/.config/git/`, `~/.ssh/`** — git/SSH config (read-only)
- **`SSH_AUTH_SOCK`** — SSH agent forwarding
- **`ANTHROPIC_API_KEY`** — API key (if set)
- **`/nix/store`** — Nix store (read-only) + daemon socket; the VM shares the host store read-only and adds a per-project writable overlay

## Available packages

| Package | Binary | Description |
|---|---|---|
| `default` | `claude-sandbox`, `claude` | Bubblewrap sandbox + un-sandboxed claude-code (bundled) |
| `sandbox` | `claude-sandbox` | Bubblewrap sandbox only |
| `no-network` | `claude-sandbox` | Bubblewrap without network |
| `container` | `claude-sandbox-container` | systemd-nspawn with network |
| `container-no-network` | `claude-sandbox-container` | systemd-nspawn without network |
| `vm` | `claude-sandbox-vm` | microvm.nix VM with NAT + sandbox LAN |
| `vm-no-network` | `claude-sandbox-vm` | microvm.nix VM with sandbox LAN only |
| `manager` | `claude-sandbox-manager` | Remote sandbox manager daemon |
| `cli` | `claude-remote` | CLI for remote management |

Build any package with:

```bash
nix build github:jhhuh/claude-code-nix-sandbox#<package>
```
