# QEMU VM Backend

The strongest isolation backend. Runs a full NixOS virtual machine with a separate kernel. Claude Code runs on the serial console (in your terminal), while Chromium renders in the QEMU display window (Xorg + Openbox).

## Usage

```bash
# Build
nix build github:jhhuh/claude-code-nix-sandbox#vm

# Run
./result/bin/claude-sandbox-vm /path/to/project
./result/bin/claude-sandbox-vm --shell /path/to/project
./result/bin/claude-sandbox-vm --headless /path/to/project  # no QEMU window

# Without network
nix build github:jhhuh/claude-code-nix-sandbox#vm-no-network
./result/bin/claude-sandbox-vm /path/to/project
```

## How it works

The backend imports `nix/sandbox-spec.nix` for the canonical package list and Chrome extension IDs, then evaluates a NixOS VM configuration using the `qemu-vm.nix` module. The VM is configured with:

- **4 GB RAM, 4 cores** (defaults from `virtualisation` module)
- **Serial console on stdio** for Claude Code interaction
- **QEMU GTK window** running Xorg + Openbox for Chromium display (omitted automatically on headless hosts)
- **9p filesystem shares** for project directory, auth, git config, SSH keys, and metadata

### Console setup

The VM has two consoles: `tty0` (QEMU window) and `ttyS0` (serial/stdio). The serial console is listed last in `virtualisation.qemu.consoles` so Linux makes it `/dev/console`. Getty auto-logs in the `sandbox` user on ttyS0.

A tty guard in `interactiveShellInit` ensures the entrypoint (Claude Code or bash) only runs on ttyS0, not on the graphical tty0. See `artifacts/skills/nixos-qemu-vm-serial-console-setup.md`.

### Headless operation

With `virtualisation.graphics = true`, nixpkgs' `qemu-vm.nix` passes no `-display` flag, so QEMU falls back to its default GTK UI — which fails with `gtk initialization failed` when there is no display (e.g. a plain SSH session on a server).

The launcher auto-detects this: if neither `DISPLAY` nor `WAYLAND_DISPLAY` points to a usable display (a set `DISPLAY` is probed with `xset` to catch stale SSH X11 forwarding), it appends `-display none` to `QEMU_OPTS`. Only the host-side window is dropped — the guest's Xorg and Chromium still render to the emulated VGA, and Claude Code still runs on the serial console. `--headless` forces this even when a display is available.

To watch a headless VM's screen from another machine, add a VNC viewer on top of the disabled frontend:

```bash
QEMU_OPTS="-vnc :0" ./result/bin/claude-sandbox-vm /path/to/project
```

(QEMU keeps a single `-display` config and the last `-display` wins, so a user-provided `QEMU_OPTS` is appended after the launcher's flags and overrides them.) See `artifacts/skills/nixos-qemu-vm-headless-display-none.md`.

### 9p filesystem shares

| Mount point | Tag | Mode | Description |
|---|---|---|---|
| `/project` | `project_share` | Read-write | Project directory |
| `/home/sandbox/.claude` | `claude_auth` | Read-write, nofail | Auth persistence |
| `/home/sandbox/.gitconfig` | `git_config` | Read-only, nofail | Git config |
| `/home/sandbox/.config/git` | `git_config_dir` | Read-only, nofail | Git config directory |
| `/home/sandbox/.config/gh` | `gh_config_dir` | Read-only, nofail | GitHub CLI config |
| `/home/sandbox/.ssh` | `ssh_dir` | Read-only, nofail | SSH keys |
| `/mnt/meta` | `claude_meta` | Read-only | Entrypoint and API key |

Shares use `msize=104857600` (100 MB) for the project directory to improve I/O throughput. The `nofail` option allows the VM to boot even if the host directory doesn't exist.

### Metadata passing

The entrypoint command, API key, GitHub token, and locale settings are written to a temporary directory on the host and shared via 9p as `/mnt/meta`. The VM reads these files during shell init:

- `/mnt/meta/entrypoint` — command to run (claude or bash)
- `/mnt/meta/apikey` — Anthropic API key
- `/mnt/meta/host_home` — host user's home path (for path reconstruction)
- `/mnt/meta/host_project` — host project path (for bind-mount)
- `/mnt/meta/claude.json` — Claude config file
- `/mnt/meta/gh_token` — GitHub token (when `--gh-token` is used)
- `/mnt/meta/lang` — LANG locale setting
- `/mnt/meta/lc_all` — LC_ALL locale setting

## Nix parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `network` | bool | `true` | Enable DHCP networking (false empties `vlans`) |
| `extraModules` | list of NixOS modules | `[]` | Extra NixOS config for the VM |
| `nixos` | function | (required) | NixOS evaluator |

## Customization example

```nix
pkgs.callPackage ./nix/backends/vm.nix {
  nixos = args: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = args.imports;
  };
  extraModules = [{
    virtualisation.memorySize = 8192;
    virtualisation.cores = 8;
    environment.systemPackages = with pkgs; [ python3 ];
  }];
}
```

## Requirements

- KVM recommended (`/dev/kvm`) for reasonable performance
- Works without KVM but is significantly slower (software emulation)
