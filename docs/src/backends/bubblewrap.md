# Bubblewrap Backend

The default backend. Uses [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) to create a lightweight sandbox using Linux user namespaces. No root required.

## Usage

```bash
# Build
nix build github:jhhuh/claude-code-nix-sandbox

# Run
./result/bin/claude-sandbox /path/to/project
./result/bin/claude-sandbox --shell /path/to/project

# Run inside tmux (needed for agent teams)
./result/bin/claude-sandbox --tmux /path/to/project

# Without network
nix build github:jhhuh/claude-code-nix-sandbox#no-network
./result/bin/claude-sandbox /path/to/project
```

## How it works

The sandbox script imports `nix/sandbox-spec.nix` for the canonical package list and builds a `symlinkJoin` of `spec.packages` plus chromiumSandbox and any `extraPackages` into a single PATH. Host `/etc` paths are also driven by the spec. It then calls `bwrap` with:

- **Filesystem**: `/nix/store` read-only, project directory read-write, `~/.claude` read-write, `/home` as tmpfs
- **Display**: X11 socket + Xauthority, Wayland socket forwarded
- **D-Bus**: system bus and session bus forwarded (Chromium isolated from session bus via `env -u DBUS_SESSION_BUS_ADDRESS` in wrapper to prevent singleton collisions)
- **GPU**: `/dev/dri` and `/run/opengl-driver` forwarded for hardware acceleration
- **Audio**: PipeWire and PulseAudio sockets forwarded
- **Network**: shared with host by default, `--unshare-net` when `network = false`
- **Resources**: RAM/CPU limits are NOT enforceable here — bwrap is
  unprivileged and has no cgroup authority. Use the container
  (`--mem`/`--cpus` → `MemoryMax`/`CPUQuota`) or VM (`--mem`/`--cpus`)
  backend when limits matter.
- **Nix**: daemon socket forwarded with `NIX_REMOTE=daemon`

The sandbox home is `/home/sandbox`. The process runs as your user (no UID mapping).

## tmux mode (`--tmux`)

The `--tmux` flag starts claude-code inside a tmux session, required for Claude Code's experimental agent teams feature. The tmux state is stored per-project in `<project-dir>/.tmux/`:

- **`tmux.conf`** — minimal config, created on first run, editable and persistent across restarts
- **`socket`** — tmux server socket (runtime, per-project to avoid collisions)

The session is named `sandbox:<project-name>` with an orange status bar to visually distinguish it from host tmux sessions.

## Nix parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `network` | bool | `true` | Allow network access (false adds `--unshare-net`) |
| `extraPackages` | list of packages | `[]` | Additional packages on PATH inside the sandbox |

## Customization example

```nix
pkgs.callPackage ./nix/backends/bubblewrap.nix {
  extraPackages = [ pkgs.python3 pkgs.nodejs ];
  network = false;
}
```

## Requirements

- Linux with user namespace support (`boot.kernel.sysctl."user.max_user_namespaces"` > 0 on NixOS — set automatically by the sandbox NixOS module)
- X11 or Wayland display server
