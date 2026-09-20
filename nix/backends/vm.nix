# QEMU VM backend for Claude Code + Chromium
#
# Usage: claude-sandbox-vm [--shell] [--gh-token] [--headless] [project-dir] [-- claude args...]
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
  virtiofsd,
  xorg,
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
          docker.enable = true;
          diskImage = "$HOME/.claudesandbox/claude-sandbox-vm.qcow2";
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
        #
        # All shares ride virtiofs (device = the virtiofsd mount tag; the
        # launcher exports each tag). 9p cannot mmap shared files, and every
        # omp database under ~/.omp is WAL-mode SQLite whose wal-index lives
        # in a shared mmap of the -shm file — over 9p omp died at startup
        # with SQLITE_IOERR_SHMMAP (can1357/oh-my-pi#9082). virtiofsd serves
        # mmap and fcntl byte-range locks through to the host kernel, which
        # is the all-processes-on-one-host access pattern WAL is defined for;
        # concurrent VMs sharing ~/.omp stay coherent because their locks
        # meet in that single host kernel.

        # Project directory (host path passed at runtime by the launcher's
        # virtiofsd for this tag)
        virtualisation.fileSystems."/project" = {
          device = "project_share";
          fsType = "virtiofs";
          noCheck = true;
        };

        # Claude auth (nofail: dir may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.claude" = {
          device = "claude_auth";
          fsType = "virtiofs";
          options = [ "nofail" ];
          noCheck = true;
        };

        # omp ("oh my pi") agent config + auth — read-WRITE, unlike the
        # git/gh/ssh shares below: omp rewrites ~/.omp/agent/config.yml at
        # runtime under an advisory lock, so a ro share would break every
        # launch. The launcher seeds that file host-side before virtiofsd
        # starts (the share exports the host directory wholesale; a single
        # file inside it cannot be shared on its own — the same reason
        # .gitconfig rides the meta dir). Mirrors claude_auth: nofail covers
        # a skipped share.
        virtualisation.fileSystems."/home/sandbox/.omp" = {
          device = "omp_auth";
          fsType = "virtiofs";
          options = [ "nofail" ];
          noCheck = true;
        };

        # Git per-directory config (nofail: may not exist on host).
        # ~/.gitconfig is a FILE, not a directory, and virtiofsd can only
        # export directories — so that file is seeded by copy through the
        # meta dir instead (see the launcher script and interactiveShellInit
        # below).
        virtualisation.fileSystems."/home/sandbox/.config/git" = {
          device = "git_config_dir";
          fsType = "virtiofs";
          options = [ "ro" "nofail" ];
          noCheck = true;
        };

        # GitHub CLI config (nofail: dir may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.config/gh" = {
          device = "gh_config_dir";
          fsType = "virtiofs";
          options = [ "ro" "nofail" ];
          noCheck = true;
        };

        # SSH keys (nofail: dir may not exist on host)
        virtualisation.fileSystems."/home/sandbox/.ssh" = {
          device = "ssh_dir";
          fsType = "virtiofs";
          options = [ "ro" "nofail" ];
          noCheck = true;
        };

        # Metadata (entrypoint, API key)
        virtualisation.fileSystems."/mnt/meta" = {
          device = "claude_meta";
          fsType = "virtiofs";
          options = [ "ro" ];
          noCheck = true;
        };

        # Per-project state dir — writable, unlike the config shares.
        # Carries ~/.local so pipx/npm/venv installs survive VM restarts.
        virtualisation.fileSystems."/mnt/state" = {
          device = "state_dir";
          fsType = "virtiofs";
          options = [ "nofail" ];
          noCheck = true;
        };

        # Guest-side virtiofs client for the fstab entries above.
        boot.kernelModules = [ "virtio_fs" ];

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
              # Symlink dotfiles from the fixed share mounts to the real
              # home path (.omp included: omp's config + auth live there)
              for item in .claude .omp .config .ssh; do
                if [[ -e "/home/sandbox/$item" ]]; then
                  ln -sfn "/home/sandbox/$item" "$host_home/$item"
                fi
              done
              # .gitconfig is a file, not a directory — a share can only
              # export a directory, so copy it from metadata (like
              # claude.json below).
              if [[ -f /mnt/meta/gitconfig ]]; then
                cp /mnt/meta/gitconfig "$host_home/.gitconfig"
                chmod 644 "$host_home/.gitconfig"
              fi
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
          extraGroups = [ "video" "audio" "wheel" "docker" ];
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
  runtimeInputs = [ coreutils socat virtiofsd xorg.xset ];

  text = ''
    shell_mode=false
    enter_mode=false
    gh_token=false
    headless_mode=false
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
      echo "  --headless  Force -display none even when a display is available" >&2
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shell)    shell_mode=true; shift ;;
        --enter)    enter_mode=true; shift ;;
        --gh-token) gh_token=true; shift ;;
        --headless) headless_mode=true; shift ;;
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
    # and a SQLite-backed browser profile on a shared filesystem risks
    # locking problems.
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

    # Clean up stale metadata temp dirs from previous runs killed with SIGKILL.
    # The disk image is now persistent (see below), so it is deliberately NOT
    # swept here — only the per-run metadata dir is ephemeral.
    for stale in /tmp/claude-vm-meta.*/; do
      [[ -d "$stale" ]] || continue
      rm -rf "$stale"
    done

    # Create metadata directory (entrypoint + API key)
    meta_dir="$(mktemp -d /tmp/claude-vm-meta.XXXXXX)"

    disk_root="$HOME/.claudesandbox"
    mkdir -p "$disk_root"
    NIX_DISK_IMAGE="$disk_root/$sd_base-$sd_hash.qcow2"
    export NIX_DISK_IMAGE
    # PIDs of the per-share virtiofsd daemons (populated by start_vfsd below);
    # the trap tears them down alongside the metadata dir and disk image.
    vfsd_pids=()
    trap 'rm -rf "$meta_dir" "$NIX_DISK_IMAGE"; if [[ "''${#vfsd_pids[@]}" -gt 0 ]]; then kill "''${vfsd_pids[@]}" 2>/dev/null || true; fi' EXIT

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

    # Share project, metadata, and auth dirs via virtiofs.
    #
    # Each directory gets its own virtiofsd instance — one vhost-user socket
    # per tag, in the per-launch meta_dir so concurrent VMs never collide —
    # attached to the guest as a vhost-user-fs-pci device; the
    # guest fstab (virtualisation.fileSystems above) mounts each tag. The
    # generated run script already provides what vhost-user requires:
    # shared guest RAM (`-object memory-backend-memfd,id=mem0,share=on
    # -machine memory-backend=mem0`, sized from virtualisation.memorySize)
    # and its own virtiofsd daemons for nix-store/xchg/shared.
    #
    # Why virtiofs instead of 9p: every omp database under ~/.omp is
    # WAL-mode SQLite, and WAL's wal-index needs a shared mmap of the -shm
    # file. 9p cannot mmap shared files, so omp died at startup with
    # SQLITE_IOERR_SHMMAP (can1357/oh-my-pi#9082). virtiofsd serves mmap and
    # fcntl byte-range locks through to the host kernel — the
    # all-processes-on-one-host access pattern WAL requires. Concurrent VMs
    # stay coherent because their locks serialize in that single kernel.
    qemu_extra=()

    # Start one virtiofsd exporting `dir` under `tag`. "ro" adds --readonly
    # (the host-side equivalent of 9p's readonly=on); rw adds --writeback,
    # matching the run script's own rw daemons. The daemon logs into the
    # state dir; its socket appearing is the readiness signal — if it dies
    # instead, surface its log rather than a cryptic QEMU chardev error.
    start_vfsd() {
      local tag="$1" dir="$2" mode="$3"
      # Socket in the short per-launch meta_dir: a unix socket path must be
      # shorter than SUN_LEN (108), and the state dir can nest arbitrarily
      # deep. The trap's `rm -rf "$meta_dir"` removes them with the rest.
      local sock="$meta_dir/vfsd-$tag.sock"
      local pid
      rm -f "$sock"
      if [[ "$mode" == ro ]]; then
        virtiofsd --socket-path "$sock" --shared-dir "$dir" --readonly >"$state_dir/virtiofsd-$tag.log" 2>&1 &
      else
        virtiofsd --socket-path "$sock" --shared-dir "$dir" --writeback >"$state_dir/virtiofsd-$tag.log" 2>&1 &
      fi
      pid=$!
      vfsd_pids+=("$pid")
      for ((i = 0; i < 50; i++)); do
        [[ -S "$sock" ]] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      if [[ ! -S "$sock" ]]; then
        echo "Error: virtiofsd for $tag ($dir) failed to start:" >&2
        cat "$state_dir/virtiofsd-$tag.log" >&2
        exit 1
      fi
      qemu_extra+=(-chardev "socket,id=charvfs_$tag,path=$sock" -device "vhost-user-fs-pci,chardev=charvfs_$tag,tag=$tag")
    }

    start_vfsd project_share "$project_dir" rw
    start_vfsd claude_meta "$meta_dir" ro
    start_vfsd state_dir "$state_dir" rw
    # Second serial device -> guest ttyS1. Appended after the build-time
    # "-serial stdio", so stdio stays ttyS0 (the console claude runs on) and
    # this becomes ttyS1. A stale socket from a killed VM would block bind.
    rm -f "$console_sock"
    qemu_extra+=(-serial "unix:$console_sock,server,nowait")

    host_claude_dir="''${HOME}/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      start_vfsd claude_auth "$host_claude_dir" rw
    fi

    # omp ("oh my pi"): seed host ~/.omp/agent/config.yml when missing, then
    # share the directory rw (omp rewrites its config at runtime). Unconditional
    # — unlike the -d-guarded claude_auth above — because the seed guarantees
    # the directory exists before the export.
    ${spec.ompConfigSnippet}
    start_vfsd omp_auth "$HOME/.omp" rw

    if [[ -f "$HOME/.gitconfig" ]]; then
      cp "$HOME/.gitconfig" "$meta_dir/gitconfig"
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      start_vfsd git_config_dir "$HOME/.config/git" ro
    fi
    if [[ -d "$HOME/.config/gh" ]]; then
      start_vfsd gh_config_dir "$HOME/.config/gh" ro
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      start_vfsd ssh_dir "$HOME/.ssh" ro
    fi

    # Headless handling. qemu-vm.nix with graphics=true emits NO -display
    # flag, so QEMU falls back to its default UI (GTK in the nixpkgs build)
    # and dies with "gtk initialization failed" when nothing can open a
    # window (plain SSH, or DISPLAY leaked into tmux from a dead session).
    # -display none only drops the host-side window: the guest's Xorg and
    # Chromium render to the emulated VGA regardless, and claude talks over
    # the -serial stdio console.
    if [[ "$headless_mode" != true ]]; then
      if [[ -n "''${DISPLAY:-}" ]]; then
        # DISPLAY set but unreachable (stale SSH -X, dead tmux env):
        # probe the X server. `if !` keeps errexit off the failing probe.
        if ! xset -q >/dev/null 2>&1; then
          headless_mode=true
        fi
      elif [[ -n "''${WAYLAND_DISPLAY:-}" && -n "''${XDG_RUNTIME_DIR:-}" ]]; then
        # Wayland only: no X client for a cheap probe, check the
        # compositor socket directly (same convention as bubblewrap.nix).
        if [[ ! -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
          headless_mode=true
        fi
      else
        # Neither DISPLAY nor a complete Wayland env: definitely headless.
        # This is the branch a plain SSH session (and the manager, which
        # launches VMs without DISPLAY) hits.
        headless_mode=true
      fi
    fi
    if [[ "$headless_mode" == true ]]; then
      # Two separate array elements: $QEMU_OPTS is word-split by the
      # generated run script, so QEMU must see "-display" and "none".
      qemu_extra+=(-display none)
      echo "Headless: no usable display, starting QEMU without a window (Chromium still renders inside the VM)" >&2
    fi

    # QEMU keeps a single display config and the LAST -display wins, so a
    # user-provided QEMU_OPTS appended here overrides our default (e.g.
    # QEMU_OPTS='-vnc :0' to watch a headless VM from another machine).
    export QEMU_OPTS="''${qemu_extra[*]} ''${QEMU_OPTS:-}"
    ${vmScript}/bin/run-claude-sandbox-vm
  '';
}
# Expose the guest system closure so checks can assert against the generated
# config. Needed because the mkVMOverride trap (see the 9p mount fix) produces
# a VM that builds perfectly and silently mounts nothing — no build-based
# check can catch it, only an assertion on the guest's fstab.
// {
  vmSystem = vmSystem.config.system.build.toplevel;
}
