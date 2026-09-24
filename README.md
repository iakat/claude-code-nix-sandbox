# claude-code-nix-sandbox

> **Warning:** This project is under active development and should be considered unstable. Features may be incomplete, broken, or change without notice. If you choose to run it, you do so at your own risk. There are no guarantees of correctness, security, or fitness for any particular purpose.

**[Documentation](https://jhhuh.github.io/claude-code-nix-sandbox/)**

Launch sandboxed [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code) sessions with Chromium using Nix.

Claude Code (from [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)) runs inside an isolated sandbox with filesystem isolation, display forwarding, and a Chromium browser. Three backends available with increasing isolation: [bubblewrap](https://github.com/containers/bubblewrap) (unprivileged), [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) (root), and a [microvm.nix](https://github.com/microvm-nix/microvm.nix) VM (strongest).

## Web Dashboard

![Dashboard — sandbox list with live screenshots and system metrics](docs/src/images/dashboard.png)

![Sandbox detail — live screenshot, Claude metrics, and WebSocket log viewer](docs/src/images/sandbox-detail.png)

## Quick Start

### Install (both sandboxed and un-sandboxed)

```bash
# Install both claude-sandbox and claude-code
nix profile install github:jhhuh/claude-code-nix-sandbox

# Update to latest
nix profile upgrade claude-code-nix-sandbox --refresh
```

This gives you both `claude-sandbox` (bubblewrap isolation) and `claude` (un-sandboxed) on your PATH, pinned to the same version.

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
# Build the container package
nix build github:jhhuh/claude-code-nix-sandbox#container

# Run Claude Code in an nspawn container
sudo ./result/bin/claude-sandbox-container /path/to/project

# Shell mode
sudo ./result/bin/claude-sandbox-container --shell /path/to/project
```

### microvm.nix VM (strongest isolation)

```bash
# Build the VM package
nix build github:jhhuh/claude-code-nix-sandbox#vm

# Run omp in a VM: tmux on the serial console in your terminal (prefix Ctrl-a),
# Chromium headless inside the guest (no host window)
./result/bin/claude-sandbox-vm /path/to/project

# Shell mode (tmux + bash)
./result/bin/claude-sandbox-vm --shell /path/to/project

# Size the guest per launch (no rebuild; env: CLAUDE_SANDBOX_MEM / CLAUDE_SANDBOX_CPUS).
# Container backend takes the same flags as ceilings (MemoryMax/CPUQuota).
./result/bin/claude-sandbox-vm --mem 8192 --cpus 8 /path/to/project
```

The guest is a NixOS system built with [microvm.nix](https://github.com/microvm-nix/microvm.nix) on QEMU, on the `microvm` machine type (no display device, no PCI — every device rides virtio-mmio). **KVM (`/dev/kvm`) is required**; to run it from inside a sandbox, use the `sandbox-kvm` package, which binds the device through. The host `/nix/store` is shared read-only and overlaid with a per-project writable layer, so no per-VM copy of the base image is written — only the delta. Every VM started from the same state root shares a private LAN and can reach the others.

Requires `ANTHROPIC_API_KEY` in your environment, or an existing `~/.claude` login (auto-mounted).

Git push/pull works inside all sandboxes — `~/.gitconfig`, `~/.config/git/`, `~/.ssh/`, and `SSH_AUTH_SOCK` are forwarded read-only. Nix commands work too (`NIX_REMOTE=daemon`).

## What's Sandboxed

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
| Locale | Forwarded | Forwarded | NixOS default |
| Kernel | Shared | Shared | Separate |

## Packages

| Package | Description | Requires |
|---|---|---|
| `default` | Bubblewrap sandbox + un-sandboxed claude-code (bundled) | User namespaces |
| `sandbox` | Bubblewrap sandbox only | User namespaces |
| `no-network` | Bubblewrap sandbox (no network) | User namespaces |
| `container` | systemd-nspawn (network) | root (sudo) |
| `container-no-network` | systemd-nspawn (isolated) | root (sudo) |
| `sandbox-kvm` | bubblewrap sandbox with `/dev/kvm` (run the VM inside it) | — |
| `vm` | microvm.nix VM (NAT + sandbox LAN) | KVM required |
| `vm-no-network` | microvm.nix VM (no NAT; sandbox LAN only) | KVM required |
| `manager` | Remote sandbox manager daemon | — |
| `cli` | `claude-remote` CLI | SSH access to server |

## Remote Sandbox Manager

Run sandboxes on a remote server and manage them from your laptop via a web dashboard or CLI.

```
laptop                              remote server
  │                                   │
  │  claude-remote create ...         │ manager daemon (127.0.0.1:3000)
  │ ─────────────────────────────────>│   ├── starts Xvfb display
  │                                   │   ├── starts tmux session
  │  claude-remote attach <id>        │   ├── runs sandbox backend
  │ ─────────────────────────────────>│   ├── captures screenshots
  │                                   │   └── collects metrics
  │  claude-remote ui                 │
  │  open http://localhost:3000       │ web dashboard (htmx, live refresh)
  │ ─────────────────────────────────>│
```

### Running the Manager

```bash
# Build and run locally
nix build .#manager
MANAGER_LISTEN=127.0.0.1:3000 ./result/bin/claude-sandbox-manager

# Or deploy via NixOS module (see below)
```

The manager listens on `127.0.0.1:3000` by default. Environment variables:

| Variable | Default | Description |
|---|---|---|
| `MANAGER_LISTEN` | `127.0.0.1:3000` | Listen address |
| `MANAGER_STATE_DIR` | `.` | Directory for `state.json` |
| `MANAGER_STATIC_DIR` | (set by wrapper) | Path to static assets |

### CLI (`claude-remote`)

Available in the devShell or via `nix build .#cli`. All commands run over SSH — no direct HTTP from your laptop.

```bash
export CLAUDE_REMOTE_HOST=myserver  # required
export CLAUDE_REMOTE_PORT=3000      # optional, default 3000

claude-remote create my-project bubblewrap /home/user/project
claude-remote create isolated bubblewrap /tmp/test --no-network
claude-remote list
claude-remote attach <id>           # SSH + tmux attach
claude-remote stop <id>
claude-remote delete <id>
claude-remote metrics               # system metrics
claude-remote metrics <id>          # system + sandbox Claude metrics
claude-remote ui                    # SSH tunnel, then open http://localhost:3000
```

### Web Dashboard

The dashboard shows all sandboxes with live screenshots, status badges, and system metrics. Sandbox detail pages include Claude session metrics (tokens, tool uses, message count), a live screenshot feed, and a real-time log viewer that streams tmux output via WebSocket.

Auto-refreshes via htmx (no JavaScript build step). Access it by running `claude-remote ui` to set up an SSH tunnel, then open `http://localhost:3000`.

### REST API

All endpoints are also available as JSON:

```bash
# Create sandbox
curl -X POST localhost:3000/api/sandboxes \
  -H 'Content-Type: application/json' \
  -d '{"name":"test","backend":"bubblewrap","project_dir":"/tmp/test","network":true}'

# List / get / stop / delete
curl localhost:3000/api/sandboxes
curl localhost:3000/api/sandboxes/<id>
curl -X POST localhost:3000/api/sandboxes/<id>/stop
curl -X DELETE localhost:3000/api/sandboxes/<id>

# Screenshots, logs, and metrics
curl localhost:3000/api/sandboxes/<id>/screenshot -o screenshot.png
curl localhost:3000/api/sandboxes/<id>/logs          # full log as text/plain
curl localhost:3000/api/sandboxes/<id>/metrics
curl localhost:3000/api/metrics/system

# WebSocket log streaming (real-time)
# ws://localhost:3000/ws/sandboxes/<id>/logs
```

## NixOS Modules

### Sandbox backends

For NixOS users, a declarative module is available:

```nix
# flake.nix
{
  inputs.claude-sandbox.url = "github:jhhuh/claude-code-nix-sandbox";

  outputs = { nixpkgs, claude-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-sandbox.nixosModules.default
        {
          services.claude-sandbox = {
            enable = true;           # Install bubblewrap backend (default)
            container.enable = true; # Also install container backend
            vm.enable = true;        # Also install VM backend
            network = true;          # Allow network access (default)
            # Extra packages inside bubblewrap sandbox:
            # bubblewrap.extraPackages = with pkgs; [ python3 nodejs ];
            # Extra NixOS modules for container/VM:
            # container.extraModules = [{ environment.systemPackages = with pkgs; [ python3 ]; }];
            # vm.extraModules = [{ environment.systemPackages = with pkgs; [ python3 ]; }];
          };
        }
      ];
    };
  };
}
```

### Manager service

Deploy the remote sandbox manager as a systemd service:

```nix
# flake.nix
{
  inputs.claude-sandbox.url = "github:jhhuh/claude-code-nix-sandbox";

  outputs = { nixpkgs, claude-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-sandbox.nixosModules.manager
        {
          services.claude-sandbox-manager = {
            enable = true;
            listenAddress = "127.0.0.1:3000";  # default
            stateDir = "/var/lib/claude-manager";  # default
            # Put sandbox backends on the manager's PATH:
            sandboxPackages = [
              claude-sandbox.packages.x86_64-linux.default
            ];
            # Allow passwordless sudo for the container backend:
            # containerSudoers = true;
          };
        }
      ];
    };
  };
}
```

## Customization

Add extra packages inside the sandbox via `extraPackages` (bubblewrap) or `extraModules` (container/VM):

```nix
# Add python3 and nodejs to the bubblewrap sandbox
packages.default = pkgs.callPackage ./nix/backends/bubblewrap.nix {
  extraPackages = [ pkgs.python3 pkgs.nodejs ];
};

# Add extra NixOS config to the container
packages.container = pkgs.callPackage ./nix/backends/container.nix {
  nixos = args: nixpkgs.lib.nixosSystem { system = "x86_64-linux"; modules = args.imports; };
  extraModules = [{ environment.systemPackages = [ pkgs.python3 ]; }];
};
```

## Requirements

- NixOS or Nix with flakes enabled
- Linux (bubblewrap requires user namespaces)
- X11 or Wayland display server (bubblewrap/container)
- `/dev/kvm` (VM backend — required; `sandbox-kvm` passes it into a sandbox)
