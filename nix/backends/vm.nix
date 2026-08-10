# QEMU VM backend for Claude Code + Chromium
#
# Usage: claude-sandbox-vm [--shell] [--gh-token] [project-dir] [-- claude args...]
#        project-dir defaults to the current directory; args after -- go to claude
#
# Launches a NixOS VM via QEMU with claude-code and chromium.
# Provides the strongest isolation: separate kernel, full hardware
# virtualization. Claude runs on the serial console (in your terminal),
# Chromium renders in the QEMU display window.
{
  lib,
  pkgs,
  writeShellApplication,
  coreutils,
  nixos,
  socat,
  # Toggle host network access (set false for isolated network)
  network ? true,
  # Additional NixOS modules for the VM
  extraModules ? [ ],
}:

let
  spec = import ../sandbox-spec.nix { inherit pkgs; };

  vmSystem = nixos {
    imports = [
      ({ pkgs, modulesPath, ... }: {
        imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

        nixpkgs.config.allowUnfree = true;

        virtualisation = {
          memorySize = 4096;
          cores = 4;
          diskSize = 10240;
          graphics = true;
          diskImage = "/tmp/claude-sandbox-vm.qcow2";
          # No virtualisation.vlans: that option belongs to the NixOS test
          # framework, not qemu-vm.nix, and nixpkgs no longer defines it here.
          # A mkIf with a false condition still requires the option to exist,
          # so this failed unconditionally and blocked every .#vm build.
          # networking.useDHCP below already carries the `network` flag.
          qemu.options = [
            # Serial console on host stdio (for claude-code interaction)
            "-serial" "stdio"
          ];
        };

        # Serial console must be last so Linux makes it /dev/console
        virtualisation.qemu.consoles = [ "tty0" "ttyS0,115200n8" ];

        # Guest mounts MUST be virtualisation.fileSystems, not fileSystems:
        # qemu-vm.nix replaces the whole fileSystems attrset with mkVMOverride,
        # so plain entries are silently discarded and never reach the guest
        # fstab. They were, which meant none of these shares mounted at all.
        # Project directory via 9p (host path passed at runtime via QEMU_OPTS)
        virtualisation.fileSystems."/project" = {
          device = "project_share";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "msize=104857600" ];
          noCheck = true;
        };

        # Claude auth via 9p (nofail: dir may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.claude" = {
          device = "claude_auth";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "nofail" ];
          noCheck = true;
        };

        # Git config via 9p (nofail: may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.gitconfig" = {
          device = "git_config";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        virtualisation.fileSystems."/home/sandbox/.config/git" = {
          device = "git_config_dir";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        # GitHub CLI config via 9p (nofail: dir may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.config/gh" = {
          device = "gh_config_dir";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        # SSH keys via 9p (nofail: dir may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.ssh" = {
          device = "ssh_dir";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        # Metadata (entrypoint, API key) via 9p
        virtualisation.fileSystems."/mnt/meta" = {
          device = "claude_meta";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" ];
          noCheck = true;
        };

        # Per-project state dir via 9p — writable, unlike the config shares.
        # Carries ~/.local so pipx/npm/venv installs survive VM restarts.
        virtualisation.fileSystems."/mnt/state" = {
          device = "state_dir";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "nofail" ];
          noCheck = true;
        };

        # Minimal Xorg + WM for Chromium display (shown in QEMU window)
        services.xserver = {
          enable = true;
          windowManager.openbox.enable = true;
        };
        services.displayManager = {
          autoLogin = {
            enable = true;
            user = "sandbox";
          };
          defaultSession = "none+openbox";
        };

        # Auto-login sandbox user on serial console (ttyS0)
        services.getty.autologinUser = "sandbox";

        # Second serial console, backed by a Unix socket the launcher creates in
        # the state dir, so `--enter` can open a shell in the running VM. A VM is
        # not a namespace, so the nsenter approach the other backends use cannot
        # apply; this avoids the alternative (sshd + key provisioning + port
        # forwarding) and keeps working when the VM has no network.
        systemd.services."serial-getty@ttyS1" = {
          enable = true;
          wantedBy = [ "getty.target" ];
        };

        # Set up environment for sandbox user's login shell
        environment.interactiveShellInit = ''
          # ttyS1 is the --enter console: it gets the same host-path and
          # ~/.local setup, but must never run the entrypoint (that belongs to
          # the primary console) and must not re-bind an already-bound project.
          if [[ "$(tty)" == /dev/ttyS0 || "$(tty)" == /dev/ttyS1 ]]; then
            # Reconstruct host paths from metadata
            if [[ -f /mnt/meta/host_home ]]; then
              host_home=$(cat /mnt/meta/host_home)
              export HOME="$host_home"
              sudo mkdir -p "$host_home"
              sudo chown sandbox:users "$host_home"
              # Symlink dotfiles from fixed 9p mount to real home path
              for item in .claude .gitconfig .config .ssh; do
                if [[ -e "/home/sandbox/$item" ]]; then
                  ln -sfn "/home/sandbox/$item" "$host_home/$item"
                fi
              done
              # Claude config seeded by copy from metadata (carries
              # oauthAccount/onboarding state; guest writes stay in the VM)
              if [[ -f /mnt/meta/claude.json ]]; then
                cp /mnt/meta/claude.json "$host_home/.claude.json"
                chmod 600 "$host_home/.claude.json"
              fi
              # Persistent ~/.local from the per-project state dir. Symlinks are
              # fine here, unlike the project dir below: getcwd() resolves
              # symlinks, which matters only where a path is encoded into state.
              if [[ -d /mnt/state/local ]]; then
                mkdir -p "$host_home/.local"
                for sub in bin lib share; do
                  ln -sfn "/mnt/state/local/$sub" "$host_home/.local/$sub"
                done
                export PATH="$PATH:$host_home/.local/bin"
              fi
            fi
            if [[ -f /mnt/meta/host_project ]]; then
              host_project=$(cat /mnt/meta/host_project)
              sudo mkdir -p "$host_project"
              # Guard: the --enter console runs this too, and bind-mounting a
              # second time would stack mounts on the same path.
              if ! mountpoint -q "$host_project"; then
                sudo mount --bind /project "$host_project"
              fi
            fi

            export DISPLAY=:0
            cd "''${host_project:-/project}" 2>/dev/null || true
            if [[ -f /mnt/meta/apikey ]]; then
              export ANTHROPIC_API_KEY=$(cat /mnt/meta/apikey)
            fi
            if [[ -f /mnt/meta/gh_token ]]; then
              export GH_TOKEN=$(cat /mnt/meta/gh_token)
              export GITHUB_TOKEN=$(cat /mnt/meta/gh_token)
            fi
            if [[ -f /mnt/meta/lang ]]; then
              export LANG=$(cat /mnt/meta/lang)
            fi
            if [[ -f /mnt/meta/lc_all ]]; then
              export LC_ALL=$(cat /mnt/meta/lc_all)
            fi
            # Run entrypoint (exec replaces shell in non-interactive mode).
            # Primary console only — ttyS1 is for interactive inspection.
            if [[ "$(tty)" == /dev/ttyS0 ]] && [[ -f /mnt/meta/entrypoint ]]; then
              entrypoint=$(cat /mnt/meta/entrypoint)
              if [[ "$entrypoint" != "bash" ]]; then
                eval exec $entrypoint
              fi
            fi
          fi
        '';

        security.sudo = {
          enable = true;
          wheelNeedsPassword = false;
        };

        users.users.sandbox = {
          isNormalUser = true;
          home = "/home/sandbox";
          uid = 1000;
          extraGroups = [ "video" "audio" "wheel" ];
        };

        environment.systemPackages = spec.packages ++ [ pkgs.chromium ];

        # Signal to sandboxed tooling that this is a sandbox (see sandbox-spec.nix)
        environment.variables = {
          CLAUDE_SANDBOX = "1";
          CLAUDE_SANDBOX_BACKEND = "vm";
        };

        # nix-ld, so unpatched prebuilt binaries (npm native modules, pip
        # wheels) run. Unlike the container backend, the option is sufficient
        # here: this is a real NixOS system, so systemd boots and tmpfiles
        # installs the /lib64 loader symlink.
        programs.nix-ld = {
          enable = true;
          libraries = spec.nixLdLibraries;
        };

        networking = {
          hostName = "claude-sandbox";
          useDHCP = network;
        };

        # Forward host DNS/TLS/fonts config
        environment.etc = {
          "fonts/fonts.conf".source = lib.mkDefault "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
          # Chromium managed policy: force-install Claude in Chrome extension
          "chromium/policies/managed/default.json".text = builtins.toJSON {
            ExtensionInstallForcelist = spec.chromeExtensionIds;
          };
        };

        system.stateVersion = "24.11";
      })
    ] ++ extraModules;
  };

  vmScript = vmSystem.config.system.build.vm;
in
writeShellApplication {
  name = "claude-sandbox-vm";
  runtimeInputs = [ coreutils socat ];

  text = ''
    shell_mode=false
    enter_mode=false
    gh_token=false
    project_dir="."
    claude_args=()

    usage() {
      echo "Usage: claude-sandbox-vm [OPTIONS] [project-dir] [-- claude args...]" >&2
      echo "" >&2
      echo "  project-dir defaults to the current directory ('.')." >&2
      echo "  Anything after '--' is passed straight to claude." >&2
      echo "" >&2
      echo "  --shell     Drop into bash instead of launching claude" >&2
      echo "  --enter     Open a shell INSIDE this project's running VM" >&2
      echo "  --gh-token  Forward GH_TOKEN/GITHUB_TOKEN env vars into VM" >&2
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shell)    shell_mode=true; shift ;;
        --enter)    enter_mode=true; shift ;;
        --gh-token) gh_token=true; shift ;;
        --help|-h)  usage; exit 0 ;;
        --)         shift; claude_args=("$@"); break ;;
        -*)         echo "Unknown option: $1 (pass claude args after '--')" >&2; exit 1 ;;
        *)          project_dir="$1"; shift
                    if [[ "''${1:-}" == "--" ]]; then shift; fi
                    claude_args=("$@"); break ;;
      esac
    done

    project_dir="$(realpath "$project_dir")"
    if [[ ! -d "$project_dir" ]]; then
      echo "Error: $project_dir is not a directory" >&2
      exit 1
    fi

    ${spec.stateDirSnippet}

    # Persistent ~/.local, shared into the guest at /mnt/state and symlinked
    # into the reconstructed host home. The chromium profile is deliberately
    # NOT persisted here, unlike the other backends: this VM runs stock
    # chromium rather than the wrapper, so it ignores CHROMIUM_USER_DATA_DIR,
    # and a SQLite-backed browser profile over 9p risks locking problems.
    mkdir -p "$state_dir/local"/{bin,lib,share}

    # Socket backing the guest's second serial console (ttyS1). Lives in the
    # state dir so --enter can find it without a registry: its existence and
    # connectability ARE the liveness check.
    console_sock="$state_dir/console.sock"

    if [[ "$enter_mode" == true ]]; then
      if [[ ! -S "$console_sock" ]]; then
        echo "Error: no running VM for $project_dir" >&2
        echo "  start one with: claude-sandbox-vm $project_dir" >&2
        exit 1
      fi
      echo "Attaching to the VM's second console (Ctrl-] to detach)" >&2
      exec socat -,raw,echo=0,escape=0x1d "unix-connect:$console_sock"
    fi

    sandbox_notice=${lib.escapeShellArg (spec.sandboxNotice "vm")}"${spec.persistenceNotice "$project_dir"}"

    # Clean up stale VM temp files from previous runs killed with SIGKILL
    for stale in /tmp/claude-vm-meta.*/; do
      [[ -d "$stale" ]] || continue
      rm -rf "$stale"
    done
    for stale in /tmp/claude-sandbox-vm.*.qcow2; do
      [[ -f "$stale" ]] || continue
      if ! fuser "$stale" &>/dev/null; then
        rm -f "$stale"
      fi
    done

    # Create metadata directory (entrypoint + API key)
    meta_dir="$(mktemp -d /tmp/claude-vm-meta.XXXXXX)"
    # Use unique disk image path to avoid collisions between concurrent runs
    NIX_DISK_IMAGE="$(mktemp /tmp/claude-sandbox-vm.XXXXXX.qcow2)"
    export NIX_DISK_IMAGE
    rm -f "$NIX_DISK_IMAGE"  # QEMU creates it; we just need a unique name
    trap 'rm -rf "$meta_dir" "$NIX_DISK_IMAGE"' EXIT

    if [[ "$shell_mode" == true ]]; then
      echo "bash" > "$meta_dir/entrypoint"
    else
      printf '%q ' claude --append-system-prompt "$sandbox_notice" "''${claude_args[@]}" > "$meta_dir/entrypoint"
    fi

    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      echo "$ANTHROPIC_API_KEY" > "$meta_dir/apikey"
    fi

    # Pass host paths so VM can reconstruct them
    echo "$HOME" > "$meta_dir/host_home"
    echo "$project_dir" > "$meta_dir/host_project"

    # ~/.claude.json seeded by COPY via the meta dir (not shared live):
    # claude-code rewrites it via atomic rename, so sharing the live file
    # races with a host session. The copy carries the oauthAccount/onboarding
    # state so the VM doesn't prompt for login; guest writes stay in the VM.
    if [[ -f "''${HOME}/.claude.json" ]]; then
      cp "''${HOME}/.claude.json" "$meta_dir/claude.json"
    fi

    # Forward GH_TOKEN if requested
    if [[ "$gh_token" == true ]]; then
      if [[ -n "''${GH_TOKEN:-}" ]]; then
        echo "$GH_TOKEN" > "$meta_dir/gh_token"
      elif [[ -n "''${GITHUB_TOKEN:-}" ]]; then
        echo "$GITHUB_TOKEN" > "$meta_dir/gh_token"
      fi
    fi

    # Forward locale settings
    if [[ -n "''${LANG:-}" ]]; then
      echo "$LANG" > "$meta_dir/lang"
    fi
    if [[ -n "''${LC_ALL:-}" ]]; then
      echo "$LC_ALL" > "$meta_dir/lc_all"
    fi

    # Share project, metadata, and auth dirs via 9p
    qemu_extra=()
    qemu_extra+=(-virtfs "local,path=$project_dir,mount_tag=project_share,security_model=none,id=project_share")
    qemu_extra+=(-virtfs "local,path=$meta_dir,mount_tag=claude_meta,security_model=none,id=claude_meta,readonly=on")
    qemu_extra+=(-virtfs "local,path=$state_dir,mount_tag=state_dir,security_model=none,id=state_dir")
    # Second serial device -> guest ttyS1. Appended after the build-time
    # "-serial stdio", so stdio stays ttyS0 (the console claude runs on) and
    # this becomes ttyS1. A stale socket from a killed VM would block bind.
    rm -f "$console_sock"
    qemu_extra+=(-serial "unix:$console_sock,server,nowait")

    host_claude_dir="''${HOME}/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      qemu_extra+=(-virtfs "local,path=$host_claude_dir,mount_tag=claude_auth,security_model=none,id=claude_auth")
    fi

    if [[ -f "$HOME/.gitconfig" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.gitconfig,mount_tag=git_config,security_model=none,id=git_config,readonly=on")
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.config/git,mount_tag=git_config_dir,security_model=none,id=git_config_dir,readonly=on")
    fi
    if [[ -d "$HOME/.config/gh" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.config/gh,mount_tag=gh_config_dir,security_model=none,id=gh_config_dir,readonly=on")
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.ssh,mount_tag=ssh_dir,security_model=none,id=ssh_dir,readonly=on")
    fi

    export QEMU_OPTS="''${qemu_extra[*]}"
    exec ${vmScript}/bin/run-claude-sandbox-vm
  '';
}
# Expose the guest system closure so checks can assert against the generated
# config. Needed because the mkVMOverride trap (see the 9p mount fix) produces
# a VM that builds perfectly and silently mounts nothing — no build-based
# check can catch it, only an assertion on the guest's fstab.
// {
  vmSystem = vmSystem.config.system.build.toplevel;
}
