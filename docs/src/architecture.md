# Architecture

## Directory structure

```
flake.nix              # Entry point: packages, checks, nixosModules, devShells
nix/sandbox-spec.nix   # Single source of truth for sandbox requirements
nix/chromium.nix       # Chromium wrapper with extension policy
nix/backends/
  bubblewrap.nix       # bwrap sandbox — unprivileged, user namespaces
  container.nix        # systemd-nspawn container — requires root
  vm.nix               # microvm.nix VM — separate kernel, hardware virtualization
nix/modules/
  sandbox.nix          # NixOS module for declarative sandbox configuration
  manager.nix          # NixOS module for the manager systemd service
nix/manager/
  package.nix          # rustPlatform.buildRustPackage for the manager daemon
scripts/
  claude-remote.nix    # writeShellApplication CLI for remote management
manager/               # Rust/Axum web dashboard + REST API
  src/
    main.rs            # Axum router, background tasks (monitor + screenshot)
    state.rs           # Sandbox/ManagerState types, JSON persistence
    api.rs             # Page handlers + JSON REST API
    fragments.rs       # htmx partial handlers for auto-refreshing
    sandbox.rs         # Lifecycle: Xvfb → tmux → backend → monitor
    display.rs         # Xvfb spawn/kill, display number allocation
    session.rs         # tmux create/check/kill
    screenshot.rs      # Xvfb capture (ImageMagick) + VM QMP screendump
    metrics.rs         # sysinfo metrics + Claude JSONL session parser
  templates/           # askama HTML templates
  static/              # Vendored htmx.min.js + style.css
tests/
  manager.nix          # NixOS VM integration test
```

## Design principles

- **Pure Nix** — all orchestration is Nix expressions, no shell/Python wrappers for coordination
- **One backend per file** — each backend is a self-contained `callPackage`-able function in `nix/backends/`
- **Spec-driven** — `nix/sandbox-spec.nix` is the single source of truth for packages, extension IDs, and /etc paths. Backends import the spec and implement HOW to deliver each requirement
- **Chromium from nixpkgs** — always `pkgs.chromium`, never a manual download. Chromium is excluded from the spec because bwrap uses a `chromiumSandbox` wrapper while container/VM use stock `chromium`
- **Dynamic bash arrays** — backends build bwrap/nspawn/QEMU argument lists conditionally using bash arrays for optional features (display, D-Bus, GPU, auth, network)

## Backend pattern

Each backend follows the same structure:

1. **Nix function** with `{ lib, pkgs, writeShellApplication, ..., network ? true, extraPackages/extraModules ? [] }`
2. **Import spec** — `spec = pkgs.sandboxSpec;` for packages and /etc paths. The flake's single add-only overlay builds it with the agent harnesses (claude-code, omp, dsh) from the `llm-agents.nix` input — agent packages never resolve through any nixpkgs fixpoint
3. **Build a PATH or system closure** — `symlinkJoin` with `spec.packages` (bubblewrap) or `nixosSystem` with `spec.packages` in `environment.systemPackages` (container/VM)
4. **Generate a shell script** via `writeShellApplication` that:
   - Parses the backend's flags (`--shell`, `--gh-token`, and for the VM `--stop`) and the project directory argument
   - Conditionally builds arrays of flags for display, D-Bus, GPU, audio, auth, git, SSH, network
   - Execs the sandbox runtime (`bwrap`, `systemd-nspawn`, or microvm.nix's generated runner)

## Manager architecture

The manager daemon (`manager/src/main.rs`) runs three concurrent tokio tasks:

1. **HTTP server** — Axum router with:
   - HTML pages (askama templates): index, new sandbox form, sandbox detail
   - JSON API: CRUD for sandboxes, screenshots, metrics
   - htmx fragments: auto-refreshing partial HTML responses
   - Static file serving: vendored htmx.min.js and CSS
2. **Liveness monitor** (5s interval) — reconciles tmux sessions, marks dead sandboxes
3. **Screenshot loop** (2s interval) — captures Xvfb displays via ImageMagick `import` or QEMU QMP `screendump`

State is shared via `Arc<AppState>` with `tokio::sync::RwLock` for the manager state and screenshot cache.

## CLI architecture

`claude-remote` is a `writeShellApplication` that wraps `ssh`, `curl`, `jq`, `tmux`, `rsync`, and `fswatch`. Every API call is executed as `ssh $HOST curl -s ...` — the CLI never makes direct HTTP requests.
