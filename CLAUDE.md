# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-code-nix-sandbox** — Pure Nix machinery for launching sandboxed Claude Code sessions with Chromium browser access. Three isolation backends with increasing strength: bubblewrap (unprivileged), systemd-nspawn (root), QEMU VM (strongest).

## Architecture

```
flake.nix              # Entry point: packages, checks, nixosModules, devShells
nix/sandbox-spec.nix   # Single source of truth: packages, extension IDs, /etc paths
nix/chromium.nix       # Chromium wrapper with extension policy (accepts chromeExtensionIds)
nix/backends/
  bubblewrap.nix       # bwrap sandbox — unprivileged, user namespaces
  container.nix        # systemd-nspawn container — requires root, full namespace isolation
  vm.nix               # QEMU VM — separate kernel, hardware virtualization
nix/modules/
  sandbox.nix          # NixOS module for declarative sandbox configuration
  manager.nix          # NixOS module for the manager systemd service
nix/manager/
  package.nix          # rustPlatform.buildRustPackage for the manager daemon
scripts/
  claude-remote.nix    # writeShellApplication CLI for remote management via SSH
manager/               # Rust/Axum web dashboard + REST API
  src/
    main.rs            # Axum router, background tasks (monitor + screenshot loops)
    state.rs           # Sandbox/ManagerState types, JSON persistence, PID reconciliation
    api.rs             # Page handlers + JSON REST API (CRUD, screenshots, metrics)
    fragments.rs       # htmx partial handlers for auto-refreshing UI fragments
    sandbox.rs         # Lifecycle: allocate display → Xvfb → tmux → backend → monitor
    display.rs         # Xvfb spawn/kill, display number allocation
    session.rs         # tmux create/check/kill
    screenshot.rs      # Xvfb capture (ImageMagick import) + VM QMP screendump
    metrics.rs         # sysinfo system metrics + Claude JSONL session parser
  templates/           # askama HTML templates (base, index, new, sandbox, fragments/)
  static/              # Vendored htmx.min.js + style.css (no build step)
```

### Sandbox Backends

All backends are `callPackage`-able functions producing `writeShellApplication` derivations. They import `nix/sandbox-spec.nix` for the canonical package list, Chrome extension IDs, and `/etc` paths, then implement the backend-specific delivery mechanism. They share a common pattern: dynamic bash arrays for optional flags (display, D-Bus, GPU, auth, network).

**Bubblewrap** uses `symlinkJoin` to build PATH from packages. **Container** evaluates a NixOS config (`nixosSystem`) to get a system closure (`toplevel`), creates an ephemeral container root, and uses `setpriv` to drop from root to the real user's UID/GID (detected via `SUDO_USER`). **VM** builds a full NixOS VM with Xorg+openbox for Chromium display and serial console for claude-code interaction; shares directories via 9p.

### Remote Manager

The manager is a Rust/Axum daemon (`manager/`) that orchestrates sandboxes on a server. It starts Xvfb displays, spawns sandbox backends inside tmux sessions, captures live screenshots, and collects system + Claude session metrics. The web dashboard uses server-rendered HTML with htmx for auto-refreshing fragments (no JS build step).

`claude-remote` is a local CLI (`scripts/claude-remote.nix`) that talks to the manager over SSH (`ssh $HOST curl ...`). Commands: `create`, `list`, `attach`, `stop`, `delete`, `metrics`, `ui` (SSH tunnel for web dashboard).

State is persisted as JSON (`state.json`). On startup, the manager loads state and reconciles PIDs (marks dead sandboxes). The `package.nix` wraps the binary with ImageMagick, socat, tmux, Xvfb, and sandbox backends on PATH.

## Common Commands

```bash
# Sandbox backends
nix build                                 # Build default (bubblewrap + claude-code bundled)
nix build .#sandbox                       # Build bubblewrap sandbox only
nix build .#container                     # Build nspawn container
nix build .#vm                            # Build QEMU VM
nix flake check                           # Evaluate + build all packages
./result/bin/claude-sandbox                # Run sandboxed Claude Code (project-dir defaults to '.')
./result/bin/claude-sandbox <dir>          # Run against an explicit project dir
./result/bin/claude-sandbox <dir> -- --model opus  # Args after -- go straight to claude
./result/bin/claude-sandbox --shell <dir>  # Shell inside sandbox
./result/bin/claude-sandbox --enter <dir>  # Shell inside the RUNNING sandbox (inspect live)
./result/bin/claude-sandbox --new <dir>    # Force a fresh sandbox instead of joining
./result/bin/claude-sandbox --stop <dir>   # Terminate the project's sandbox
sudo ./result/bin/claude-sandbox-container <dir>         # Container mode
sudo ./result/bin/claude-sandbox-container --shell <dir> # Container shell
sudo ./result/bin/claude-sandbox-container --enter <dir> # Shell inside the RUNNING container
sudo ./result/bin/claude-sandbox-container --stop <dir>  # Terminate the container
nix build .#vm --builders ''             # VM (remote builder fails on initrd; build locally)
./result/bin/claude-sandbox-vm <dir>      # VM mode
./result/bin/claude-sandbox-vm --shell <dir>  # VM shell
./result/bin/claude-sandbox-vm --enter <dir>  # Shell inside the RUNNING VM (2nd serial console)

# Remote manager
nix build .#manager                       # Build manager daemon
nix build .#cli                           # Build claude-remote CLI
MANAGER_LISTEN=127.0.0.1:3001 ./result/bin/claude-sandbox-manager  # Run locally
claude-remote help                        # CLI usage (available in devShell)
claude-remote create test bubblewrap /tmp/test  # Create sandbox (needs CLAUDE_REMOTE_HOST)
claude-remote list                        # List sandboxes
claude-remote attach <id>                 # Attach to tmux session
claude-remote ui                          # SSH tunnel for web dashboard
```

## Conventions

- **Pure Nix only**: no shell/Python wrappers for orchestration
- **One backend per file** in `nix/backends/`
- **Spec-driven**: `nix/sandbox-spec.nix` is the single source of truth for packages, extension IDs, and /etc paths. Backends import it and implement delivery. Chromium is excluded from spec because bwrap uses `chromiumSandbox` wrapper while container/VM use stock `chromium`
- **Chromium from nixpkgs**: always `pkgs.chromium` inside the sandbox
- **claude-code from `sadjow/claude-code-nix`**: flake input with overlay applied to `pkgsFor` and all `nixosSystem` calls; backends reference `pkgs.claude-code` which resolves through the overlay
- **omp from `can1357/oh-my-pi`**: same overlay treatment as claude-code; ships in every sandbox via `spec.packages` (PATH-only, no launcher integration). Host `~/.omp` is shared rw in all backends; `agent/config.yml` is seeded host-side by copy when missing — omp flock-locks and rewrites it at runtime, so it must never be a store symlink or ro share
- **Backends are callPackage-able**: called via `pkgs.callPackage` in flake.nix; `pkgs` param is auto-filled and used to evaluate the spec
- **NixOS modules**: `sandbox.nix` as `nixosModules.default`, `manager.nix` as `nixosModules.manager`
- **Manager is Rust/Axum**: axum 0.7, askama 0.12, tower-http 0.5, sysinfo for metrics
- **Manager static files**: vendored htmx + CSS, no npm/build step; askama compiles templates into the binary
- **CLI uses SSH**: all API calls via `ssh $HOST curl ...`, no direct HTTP from laptop


## Project Direction

An in-progress vision for the project's long run is drafted in
`artifacts/plan_project-vision.md` — decisions made, the evidence behind them,
a four-layer blueprint, work packages, and the open questions to resume from.
It is a DRAFT, not an approved spec: read it before proposing architectural
changes, and do not implement from it without resuming that conversation.

## Skill Files

Non-obvious patterns discovered during development — read before modifying related code:

- `artifacts/skills/bubblewrap-dynamic-bash-arrays-for-optional-flags.md — bash arrays for conditional bwrap/nspawn flags`
- `artifacts/skills/nspawn-privilege-drop-without-pam.md — why `setpriv` instead of `su`/`runuser` in the container backend`
- `artifacts/skills/nixos-qemu-vm-serial-console-setup.md — console order, getty autologin, and tty guard for the VM backend`
- `artifacts/skills/nixos-qemu-vm-headless-display-none.md — graphics=true adds no -display (GTK default dies headless); append -display none via $QEMU_OPTS, probe DISPLAY with xset, last -display wins`
- `artifacts/skills/nix-daemon-socket-forwarding-in-sandboxes.md — rw socket bind + `NIX_REMOTE=daemon` for nix inside sandboxes`
- `artifacts/skills/ssh-agent-forwarding-into-sandboxes.md — socket + env var + openssh + git config forwarding`
- `artifacts/skills/sudo-aware-uid-detection-for-containers.md — dynamic UID/GID under sudo for file ownership`
- `artifacts/skills/ssh-remote-cli-printf-q-escaping.md — printf '%q' for SSH argument escaping`
- `artifacts/skills/nix-writeShellApplication-escaping-and-shellcheck.md — `''${` escaping, SC2155/SC2029, ShellCheck-as-error in writeShellApplication`
- `artifacts/skills/nixos-vm-integration-test-with-stub-services.md — nixosTest with stub backends, system user shell gotcha`
- `artifacts/skills/nix-overlay-injection-into-nixosSystem-calls.md — why overlays must be injected into every nixosSystem call`
- `artifacts/skills/vm-9p-runtime-path-fixup-for-session-continuity.md — build-time vs runtime paths, meta dir, bind-mount vs symlink for getcwd()`
- `artifacts/skills/claude-code-session-jsonl-extraction.md — JSONL structure, jq extraction patterns, session summarizer tool`
- `artifacts/skills/chromium-cross-sandbox-isolation-dbus-and-cdp.md — D-Bus singleton + CDP port conflict, per-project profile fix`
- `artifacts/skills/chromium-extension-bundling-via-managed-policy.md — why managed policy for extension install, alternatives considered, per-backend mounting`
- `artifacts/skills/claude-json-login-state-copy-seeding-vs-bind-mount.md — ~/.claude.json holds login/onboarding state; seed by copy, never bind (atomic-rename races)`
- `artifacts/skills/claude-code-copy-clipboard-needs-xclip-in-sandbox.md — /copy shells out to xclip/xsel (not OSC 52); sandbox must ship a clipboard binary; can't probe host tools from inside the sandbox`
- `artifacts/skills/nix-dual-purpose-derivation-build-and-run.md — writeShellScript + symlink for nix build (static) + nix run (serve) from one derivation`
- `artifacts/skills/unprivileged-namespace-join-into-running-bwrap-sandbox.md — per-project singleton + --enter: fd ordering, root fixup, payload-pid self-registration, --preserve-credentials, env replay, and why nsenter --wd breaks getcwd(2)`
