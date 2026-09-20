# systemd-nspawn container backend for Claude Code + Chromium
#
# Usage: claude-sandbox-container [--shell] [--gh-token] [project-dir] [-- claude args...]
#        claude-sandbox-container bind <project-dir> <host-path> [container-path]
#        project-dir defaults to the current directory; args after -- go to claude
#
# Launches a NixOS container via systemd-nspawn with claude-code and
# chromium. Auto-escalates to root via sudo. Provides stronger isolation
# than bubblewrap: separate PID, mount, IPC, and optionally network namespaces.
{
  lib,
  pkgs,
  writeShellApplication,
  systemd,
  coreutils,
  util-linux,
  chromiumSandbox,
  nix-ld,
  nixos,
  # Toggle host network access (set false for private network)
  network ? true,
  # Additional NixOS modules for the container
  extraModules ? [ ],
}:

let
  spec = import ../sandbox-spec.nix { inherit pkgs; };

  containerSystem = nixos {
    imports = [
      ({ pkgs, ... }: {
        boot.isNspawnContainer = true;

        networking.useDHCP = false;
        networking.hostName = "claude-sandbox";

        nixpkgs.config.allowUnfree = true;

        environment.systemPackages = spec.packages ++ (with pkgs; [
          chromium
          util-linux  # setpriv for privilege dropping
        ]);

        system.stateVersion = "24.11";
      })
    ] ++ extraModules;
  };

  toplevel = containerSystem.config.system.build.toplevel;
in
writeShellApplication {
  name = "claude-sandbox-container";
  runtimeInputs = [ systemd coreutils util-linux ];

  text = ''
    if [[ "$(id -u)" -ne 0 ]]; then
      exec sudo --preserve-env "$0" "$@"
    fi

    # Resolve the running container for a project. Sets $machine_name,
    # $machine_file and $project_dir, or exits with an error.
    # Shared by `bind`, `--enter` and `--stop`.
    resolve_machine() {
      project_dir="$(realpath "''${1:-.}")"
      state_home="$(getent passwd "''${SUDO_USER:-$USER}" | cut -d: -f6)"
      ${spec.stateDirSnippet}
      machine_file="$state_dir/machine"
      if [[ ! -f "$machine_file" ]]; then
        echo "Error: no running container for $project_dir" >&2
        exit 1
      fi
      machine_name="$(cat "$machine_file")"
      if ! machinectl show "$machine_name" &>/dev/null; then
        echo "Error: container $machine_name is not running" >&2
        rm -f "$machine_file"
        exit 1
      fi
    }

    # Subcommand: bind — dynamically bind-mount a host dir into a running container
    if [[ "''${1:-}" == "bind" ]]; then
      shift
      if [[ $# -lt 2 ]]; then
        echo "Usage: claude-sandbox-container bind <project-dir> <host-path> [container-path]" >&2
        exit 1
      fi
      bind_source="$(realpath "$2")"
      bind_dest="''${3:-$bind_source}"
      resolve_machine "$1"
      machinectl bind "$machine_name" "$bind_source" "$bind_dest"
      exit $?
    fi

    # --stop / --enter against a running container.
    #
    # NOT machinectl shell/login: those ask the container's own systemd to spawn
    # the process, and this backend runs bash under --as-pid2 rather than booting
    # systemd, so there is nothing inside to service the request. nsenter against
    # the machine leader works regardless of what PID 1 is.
    if [[ "''${1:-}" == "--stop" ]]; then
      shift
      resolve_machine "''${1:-.}"
      echo "Stopping container $machine_name" >&2
      machinectl terminate "$machine_name"
      rm -f "$machine_file"
      exit 0
    fi

    if [[ "''${1:-}" == "--enter" ]]; then
      shift
      resolve_machine "''${1:-.}"
      leader="$(machinectl show "$machine_name" -p Leader --value)"
      if [[ -z "$leader" ]]; then
        echo "Error: could not determine leader pid for $machine_name" >&2
        exit 1
      fi
      enter_uid="$(id -u "''${SUDO_USER:-''${USER}}")"
      enter_gid="$(id -g "''${SUDO_USER:-''${USER}}")"
      echo "Entering container $machine_name (leader $leader)" >&2
      # cd inside rather than nsenter --wd: --wd leaves the cwd unreachable from
      # the new root, so getcwd(2) fails ENOENT and every bun single-file
      # executable (claude included) dies with an opaque "could not find a file".
      # shellcheck disable=SC2016  # deliberate: expands in the container, not here
      enter_cmd='cd "$1" 2>/dev/null || cd /; shift; exec bash -l'
      exec nsenter --target "$leader" --mount --uts --ipc --pid --root -- \
        setpriv --reuid="$enter_uid" --regid="$enter_gid" --init-groups -- \
        bash -c "$enter_cmd" bash "$project_dir"
    fi

    shell_mode=false
    gh_token=false
    project_dir="."
    claude_args=()

    usage() {
      echo "Usage: claude-sandbox-container [OPTIONS] [project-dir] [-- claude args...]" >&2
      echo "       claude-sandbox-container bind <project-dir> <host-path> [container-path]" >&2
      echo "" >&2
      echo "  project-dir defaults to the current directory ('.')." >&2
      echo "  Anything after '--' is passed straight to claude." >&2
      echo "  Automatically escalates to root via sudo if needed." >&2
      echo "" >&2
      echo "  --shell     Drop into bash instead of launching claude" >&2
      echo "  --gh-token  Forward GH_TOKEN/GITHUB_TOKEN env vars into container" >&2
      echo "  --enter     Open a shell INSIDE this project's running container" >&2
      echo "  --stop      Terminate this project's container" >&2
      echo "  bind        Bind-mount a host directory into a running container" >&2
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shell)    shell_mode=true; shift ;;
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

    sandbox_notice=${lib.escapeShellArg (spec.sandboxNotice "container")}"${spec.persistenceNotice "$project_dir"}"

    # Clean up stale container roots from previous runs killed with SIGKILL
    for stale in /tmp/claude-nspawn.*/; do
      [[ -d "$stale" ]] || continue
      stale_suffix="''${stale%/}"
      stale_suffix="''${stale_suffix##*.}"
      stale_machine="claude-sandbox-$stale_suffix"
      if ! machinectl show "$stale_machine" &>/dev/null; then
        rm -rf "$stale"
      fi
    done

    # Create ephemeral container root (suffix used for unique machine name)
    container_root="$(mktemp -d /tmp/claude-nspawn.XXXXXX)"
    machine_name="claude-sandbox-''${container_root##*.}"
    trap 'rm -rf "$container_root"' EXIT

    mkdir -p "$container_root"/{bin,etc,var/lib,run,tmp,usr/bin,lib,lib64}

    # nix-ld loader shim. Created explicitly rather than via
    # programs.nix-ld.enable: that option installs the symlink through
    # systemd-tmpfiles, and this backend runs the entrypoint under --as-pid2
    # without booting systemd, so tmpfiles never fires and the option would be
    # a silent no-op.
    ln -s "${nix-ld}/libexec/nix-ld" "$container_root/lib64/${spec.ldName}"
    ln -s "${nix-ld}/libexec/nix-ld" "$container_root/lib/${spec.ldName}"

    # Standard shell paths for shebang compatibility
    ln -s "${toplevel}/sw/bin/env" "$container_root/usr/bin/env"
    ln -s "${toplevel}/sw/bin/bash" "$container_root/bin/bash"
    ln -s "${toplevel}/sw/bin/bash" "$container_root/bin/sh"
    ln -s "${toplevel}/sw/bin/bash" "$container_root/usr/bin/bash"

    # Stub files required by nspawn
    touch "$container_root/etc/os-release"
    touch "$container_root/etc/machine-id"

    # Resolve real user's UID/GID/home/name (handles sudo)
    real_uid="$(id -u "''${SUDO_USER:-''${USER}}")"
    real_gid="$(id -g "''${SUDO_USER:-''${USER}}")"
    real_home="$(getent passwd "''${SUDO_USER:-''${USER}}" | cut -d: -f6)"

    # Per-project state dir. Resolved here rather than next to the project-dir
    # check because it must live under the REAL user's home: we run under sudo,
    # so $HOME is root's. Everything the snippet creates is chowned back.
    state_home="$real_home"
    ${spec.stateDirSnippet}
    chown "$real_uid:$real_gid" \
      "$real_home/.local" "$real_home/.local/state" \
      "$state_root" "$state_root/CACHEDIR.TAG" "$state_root/projects" \
      "$state_dir" "$state_dir/path" 2>/dev/null || true
    echo "$machine_name" > "$state_dir/machine"
    chown "$real_uid:$real_gid" "$state_dir/machine"
    trap 'rm -rf "$container_root"; rm -f "$state_dir/machine"' EXIT
    real_user="''${SUDO_USER:-''${USER}}"

    # Create sandbox user with the real user's UID/GID so file ownership matches
    echo "root:x:0:0:root:/root:/bin/bash" > "$container_root/etc/passwd"
    echo "sandbox:x:$real_uid:$real_gid:sandbox:$real_home:/bin/bash" >> "$container_root/etc/passwd"
    echo "root:x:0:" > "$container_root/etc/group"
    echo "sandbox:x:$real_gid:" >> "$container_root/etc/group"
    mkdir -p "$container_root$real_home"
    mkdir -p "$container_root$project_dir"
    chown -R "$real_uid:$real_gid" "$container_root$real_home"

    # NSS config for username resolution
    echo "passwd: files" > "$container_root/etc/nsswitch.conf"
    echo "group: files" >> "$container_root/etc/nsswitch.conf"

    # Chromium managed policy: force-install Claude in Chrome extension
    mkdir -p "$container_root/etc/chromium/policies/managed"
    cp ${chromiumSandbox.extensionPolicy} "$container_root/etc/chromium/policies/managed/default.json"

    # Display forwarding args
    display_args=()
    if [[ -n "''${DISPLAY:-}" ]]; then
      display_args+=(--bind-ro=/tmp/.X11-unix:/tmp/.X11-unix)
      display_args+=(--setenv=DISPLAY="$DISPLAY")
    fi

    xauth_args=()
    xauth_file="''${XAUTHORITY:-$real_home/.Xauthority}"
    if [[ -e "$xauth_file" ]]; then
      # Copy Xauthority into the container root (bind-mount gets hidden by --ephemeral overlay)
      cp "$xauth_file" "$container_root$real_home/.Xauthority"
      chmod 644 "$container_root$real_home/.Xauthority"
      xauth_args+=(--setenv=XAUTHORITY="$real_home/.Xauthority")
      # Set container hostname to match the Xauthority cookie (keyed by hostname)
      xauth_args+=("--hostname=$(hostname)")
    fi

    wayland_args=()
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u "$real_user")}"
    wayland_display="''${WAYLAND_DISPLAY:-}"
    if [[ -n "$wayland_display" ]] && [[ -e "$runtime_dir/$wayland_display" ]]; then
      wayland_args+=("--bind-ro=$runtime_dir/$wayland_display:/run/user/$real_uid/$wayland_display")
      wayland_args+=("--setenv=WAYLAND_DISPLAY=$wayland_display")
      wayland_args+=("--setenv=XDG_RUNTIME_DIR=/run/user/$real_uid")
    fi

    # D-Bus system bus
    dbus_args=()
    if [[ -S /run/dbus/system_bus_socket ]]; then
      dbus_args+=(--bind-ro=/run/dbus/system_bus_socket)
    fi

    # D-Bus session bus forwarding.
    # Needed for Secret Service API (gnome-keyring) so `gh auth status` works.
    # Chromium is isolated from the session bus via its wrapper (env -u
    # DBUS_SESSION_BUS_ADDRESS in chromium.nix) to prevent singleton collisions.
    dbus_session_args=()
    if [[ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
      case "$DBUS_SESSION_BUS_ADDRESS" in
        unix:path=*)
          dbus_session_socket="''${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
          dbus_session_socket="''${dbus_session_socket%%;*}"
          if [[ -S "$dbus_session_socket" ]]; then
            dbus_session_args+=("--bind-ro=$dbus_session_socket:/run/user/$real_uid/bus")
            dbus_session_args+=("--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$real_uid/bus")
          fi
          ;;
      esac
    fi

    # GPU forwarding
    gpu_args=()
    if [[ -d /dev/dri ]]; then
      gpu_args+=(--bind=/dev/dri)
    fi
    if [[ -d /dev/shm ]]; then
      gpu_args+=(--bind=/dev/shm)
    fi
    if [[ -d /run/opengl-driver ]]; then
      gpu_args+=(--bind-ro=/run/opengl-driver)
    fi

    # Audio forwarding (PipeWire and PulseAudio)
    audio_args=()
    if [[ -e "$runtime_dir/pipewire-0" ]]; then
      audio_args+=("--bind-ro=$runtime_dir/pipewire-0:/run/user/$real_uid/pipewire-0")
    fi
    if [[ -e "$runtime_dir/pulse/native" ]]; then
      audio_args+=("--bind-ro=$runtime_dir/pulse:/run/user/$real_uid/pulse")
    fi

    # Keyring socket forwarding (gnome-keyring, KDE wallet)
    keyring_args=()
    if [[ -d "$runtime_dir/keyring" ]]; then
      keyring_args+=("--bind-ro=$runtime_dir/keyring:/run/user/$real_uid/keyring")
    fi

    # Claude auth and config persistence.
    # Bind ~/.claude (login token in .credentials.json, settings.json permissions).
    # ~/.claude.json is NOT bind-mounted: claude-code rewrites it via atomic
    # rename, so binding the live file races with a host session. Instead it
    # is seeded by COPY into the ephemeral container root (like .Xauthority
    # above) — carries the oauthAccount/onboarding state so the sandbox
    # doesn't prompt for login, while writes stay in the ephemeral overlay.
    claude_auth_args=()
    host_claude_dir="$real_home/.claude"
    mkdir -p "$host_claude_dir"
    chown "$real_uid:$real_gid" "$host_claude_dir"
    claude_auth_args+=(--bind="$host_claude_dir":"$real_home/.claude")
    if [[ -f "$real_home/.claude.json" ]]; then
      cp "$real_home/.claude.json" "$container_root$real_home/.claude.json"
      chown "$real_uid:$real_gid" "$container_root$real_home/.claude.json"
      chmod 600 "$container_root$real_home/.claude.json"
    fi

    # omp ("oh my pi") config + auth persistence — mirror of the ~/.claude
    # bind above, seeded host-side. We run under sudo ($HOME is root's), so
    # point the snippet at the real home and chown back what it created —
    # the same contract as the state dir snippet above.
    omp_args=()
    omp_home="$real_home"
    ${spec.ompConfigSnippet}
    chown "$real_uid:$real_gid" \
      "$real_home/.omp" "$real_home/.omp/agent" \
      "$real_home/.omp/agent/config.yml" 2>/dev/null || true
    omp_args+=(--bind="$real_home/.omp":"$real_home/.omp")

    # Per-project Chromium profile with unique user-data-dir path.
    # See bubblewrap.nix comment for why the real project path is needed.
    chromium_profile="$state_dir/chromium"
    mkdir -p "$chromium_profile"
    chown "$real_uid:$real_gid" "$chromium_profile"

    # Persistent ~/.local (pip --user / npm -g console scripts and their libs).
    # Bound whole rather than just bin/, since a --user install is split across
    # bin/ and lib/pythonX.Y/site-packages.
    mkdir -p "$state_dir/local"/{bin,lib,share}
    chown "$real_uid:$real_gid" "$state_dir/local" \
      "$state_dir/local/bin" "$state_dir/local/lib" "$state_dir/local/share"

    # Git and SSH forwarding (read-only)
    git_args=()
    if [[ -f "$real_home/.gitconfig" ]]; then
      git_args+=(--bind-ro="$real_home/.gitconfig":"$real_home/.gitconfig")
    fi
    if [[ -d "$real_home/.config/git" ]]; then
      mkdir -p "$container_root$real_home/.config/git"
      git_args+=(--bind-ro="$real_home/.config/git":"$real_home/.config/git")
    fi
    if [[ -d "$real_home/.ssh" ]]; then
      git_args+=(--bind-ro="$real_home/.ssh":"$real_home/.ssh")
    fi
    ssh_agent_args=()
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]] && [[ -e "$SSH_AUTH_SOCK" ]]; then
      ssh_agent_args+=("--bind-ro=$SSH_AUTH_SOCK:/run/user/$real_uid/ssh-agent.sock")
      ssh_agent_args+=("--setenv=SSH_AUTH_SOCK=/run/user/$real_uid/ssh-agent.sock")
    fi

    # GitHub CLI config (always mounted, like gitconfig)
    gh_args=()
    if [[ -d "$real_home/.config/gh" ]]; then
      mkdir -p "$container_root$real_home/.config/gh"
      gh_args+=(--bind-ro="$real_home/.config/gh":"$real_home/.config/gh")
    fi
    if [[ "$gh_token" == true ]]; then
      if [[ -n "''${GH_TOKEN:-}" ]]; then
        gh_args+=("--setenv=GH_TOKEN=$GH_TOKEN")
      fi
      if [[ -n "''${GITHUB_TOKEN:-}" ]]; then
        gh_args+=("--setenv=GITHUB_TOKEN=$GITHUB_TOKEN")
      fi
    fi

    # Network
    network_args=()
    ${lib.optionalString (!network) ''network_args+=(--private-network)''}

    # Select entrypoint and console mode
    console_args=()
    if [[ "$shell_mode" == true ]]; then
      entrypoint_args=(--setenv=ENTRYPOINT=bash)
    else
      entrypoint_args=(--setenv=ENTRYPOINT="$(printf '%q ' omp --append-system-prompt "$sandbox_notice" "''${claude_args[@]}")")
    fi
    entrypoint_args+=(--setenv=CLAUDE_SANDBOX=1 --setenv=CLAUDE_SANDBOX_BACKEND=container)
    # Use pipe console when stdin is not a terminal (e.g. piped commands, --version)
    if [[ ! -t 0 ]]; then
      console_args+=(--console=pipe)
    fi

    # API key
    api_key_args=()
    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      api_key_args+=(--setenv=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
    fi

    # Locale forwarding
    locale_args=()
    if [[ -n "''${LANG:-}" ]]; then
      locale_args+=(--setenv=LANG="$LANG")
    fi
    if [[ -n "''${LC_ALL:-}" ]]; then
      locale_args+=(--setenv=LC_ALL="$LC_ALL")
    fi

    # Host config forwarding (DNS, TLS, fonts, timezone, locale)
    host_cfg_args=()
    for f in ${lib.concatStringsSep " " spec.hostEtcPaths}; do
      if [[ -e "$f" ]]; then
        host_cfg_args+=("--bind-ro=$f")
      fi
    done

    # Nix store forwarding (conditional for non-NixOS hosts)
    nix_args=(--bind-ro=/nix/store)
    if [[ -d /nix/var/nix/db ]]; then
      nix_args+=(--bind-ro=/nix/var/nix/db)
    fi
    if [[ -d /nix/var/nix/daemon-socket ]]; then
      nix_args+=(--bind=/nix/var/nix/daemon-socket)
    fi

    exec systemd-nspawn \
      --quiet \
      --ephemeral \
      -M "$machine_name" \
      -D "$container_root" \
      "''${nix_args[@]}" \
      --bind="$project_dir":"$project_dir" \
      --bind="$state_dir":"$state_dir" \
      --bind="$state_dir/local/bin":"$real_home/.local/bin" \
      --bind="$state_dir/local/lib":"$real_home/.local/lib" \
      --bind="$state_dir/local/share":"$real_home/.local/share" \
      "''${host_cfg_args[@]}" \
      "''${display_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      "''${dbus_session_args[@]}" \
      "''${gpu_args[@]}" \
      "''${audio_args[@]}" \
      "''${keyring_args[@]}" \
      "''${claude_auth_args[@]}" \
      "''${omp_args[@]}" \
      "''${git_args[@]}" \
      "''${gh_args[@]}" \
      "''${ssh_agent_args[@]}" \
      "''${network_args[@]}" \
      "''${api_key_args[@]}" \
      "''${locale_args[@]}" \
      "''${entrypoint_args[@]}" \
      "''${console_args[@]}" \
      --setenv=HOME="$real_home" \
      --setenv=CHROMIUM_USER_DATA_DIR="$chromium_profile" \
      --setenv=NIX_LD="${spec.realLoader}" \
      --setenv=NIX_LD_LIBRARY_PATH="${lib.makeLibraryPath spec.nixLdLibraries}" \
      --setenv=PATH="${chromiumSandbox}/bin:${toplevel}/sw/bin:$real_home/.local/bin" \
      --setenv=TERM="''${TERM:-xterm-256color}" \
      --setenv=NIX_REMOTE=daemon \
      --as-pid2 \
      -- "${toplevel}/sw/bin/bash" -c "chown $real_uid:$real_gid $project_dir && exec ${toplevel}/sw/bin/setpriv --reuid=$real_uid --regid=$real_gid --init-groups -- ${toplevel}/sw/bin/bash -c 'cd $project_dir && eval exec \$ENTRYPOINT'"
  '';
}
