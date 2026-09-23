# systemd-nspawn Container Backend

Uses [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) for container-level isolation with separate PID, mount, and IPC namespaces. Requires root.

## Usage

```bash
# Build
nix build github:jhhuh/claude-code-nix-sandbox#container

# Run (requires sudo)
sudo ./result/bin/claude-sandbox-container /path/to/project
sudo ./result/bin/claude-sandbox-container --shell /path/to/project

# With resource ceilings
sudo ./result/bin/claude-sandbox-container --mem 8192 --cpus 4 /path/to/project

# Without network
nix build github:jhhuh/claude-code-nix-sandbox#container-no-network
sudo ./result/bin/claude-sandbox-container /path/to/project
```

## How it works

The backend imports `nix/sandbox-spec.nix` for the canonical package list and evaluates a NixOS configuration (`nixosSystem`) with `spec.packages` in `environment.systemPackages` to produce a system closure (`toplevel`). Host `/etc` paths are also driven by the spec. At runtime it:

1. Creates an ephemeral container root in `/tmp/claude-nspawn.XXXXXX`
2. Creates stub files (`os-release`, `machine-id`) and passwd/group entries
3. Detects the real user's UID/GID via `SUDO_USER` for file ownership
4. Launches `systemd-nspawn --ephemeral` with bind-mounts for the project, display, audio, GPU, etc.
5. Runs as PID2 (`--as-pid2`), then uses `setpriv` to drop from root to the real user's UID/GID

The project directory is mounted at `/project` inside the container.

### Why setpriv instead of su/runuser

The container uses `setpriv --reuid --regid --init-groups` to drop privileges because `su` and `runuser` require PAM, which isn't available in the minimal container environment. See `artifacts/skills/nspawn-privilege-drop-without-pam.md` for details.

### UID/GID mapping

The real user's UID and GID are detected from `SUDO_USER`/`SUDO_HOME` environment variables (set by sudo). A `sandbox` user is created inside the container with matching UID/GID so that files created in the project directory have correct ownership on the host. See `artifacts/skills/sudo-aware-uid-detection-for-containers.md`.

### Resource limits

`--mem` (MiB) and `--cpus` (whole CPUs) set ceilings on the container, applied
as systemd `MemoryMax` / `CPUQuota` properties on the machine's scope unit in
the **host's** systemd — enforced even though the payload runs under
`--as-pid2`, and visible via `machinectl show`. Precedence: flags beat
`CLAUDE_SANDBOX_MEM` / `CLAUDE_SANDBOX_CPUS`, which beat the build-time
defaults (unset = unlimited). `--cpus 4` becomes `CPUQuota=400%`.

## Nix parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `network` | bool | `true` | Allow network access (false adds `--private-network`) |
| `mem` | int (MiB) or null | `null` | Default memory ceiling (`MemoryMax`); override via `--mem` / `CLAUDE_SANDBOX_MEM` |
| `cpus` | int or null | `null` | Default CPU ceiling (`CPUQuota`); override via `--cpus` / `CLAUDE_SANDBOX_CPUS` |
| `extraModules` | list of NixOS modules | `[]` | Extra NixOS config for the container |
| `nixos` | function | (required) | NixOS evaluator, typically `args: nixpkgs.lib.nixosSystem { ... }` |

## Customization example

```nix
pkgs.callPackage ./nix/backends/container.nix {
  nixos = args: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = args.imports;
  };
  extraModules = [{
    environment.systemPackages = with pkgs; [ python3 nodejs ];
  }];
}
```

## Forwarded resources

- X11 display socket and Xauthority (copied into container root)
- Wayland socket
- D-Bus system bus and session bus (Chromium isolated from session bus via wrapper)
- GPU (`/dev/dri`, `/dev/shm`, `/run/opengl-driver`)
- PipeWire and PulseAudio sockets
- SSH agent (remapped to `/run/user/<uid>/ssh-agent.sock`)
- Git config and SSH keys (read-only)
- `~/.claude` auth directory (read-write)
- Nix store, database, and daemon socket
- Host DNS, TLS certificates, fonts, timezone
- Locale (`LANG`, `LC_ALL`)
