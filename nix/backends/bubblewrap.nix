# Bubblewrap sandbox backend for Claude Code + Chromium
#
# Usage: claude-sandbox [--shell] [--tmux] [--gh-token] [project-dir] [-- claude args...]
#        project-dir defaults to the current directory; args after -- go to claude
#
# Produces a writeShellApplication that wraps bwrap to isolate
# claude-code and chromium with access to a single project directory.
# Automatically bind-mounts ~/.claude for auth persistence if it exists.
{
  lib,
  pkgs,
  writeShellApplication,
  symlinkJoin,
  bubblewrap,
  chromiumSandbox,
  coreutils,
  util-linux,
  nix-ld,
  # Toggle host network access (set false to --unshare-net)
  network ? true,
  # Bind /dev/kvm into the sandbox (nested virt: lets the VM backend's QEMU
  # use KVM from inside this sandbox instead of stalling under TCG)
  kvm ? false,
  # Additional packages available inside the sandbox
  extraPackages ? [ ],
}:

let
  spec = import ../sandbox-spec.nix { inherit pkgs; };

  sandboxPath = symlinkJoin {
    name = "claude-sandbox-path";
    paths = spec.packages ++ [ chromiumSandbox ] ++ extraPackages;
  };

  networkFlags = lib.optionalString (!network) "--unshare-net";
in
writeShellApplication {
  name = "claude-sandbox";
  runtimeInputs = [ bubblewrap coreutils util-linux ];

  text = ''
    shell_mode=false
    tmux_mode=false
    gh_token=false
    enter_mode=false
    stop_mode=false
    new_mode=false
    project_dir="."
    claude_args=()

    usage() {
      echo "Usage: claude-sandbox [OPTIONS] [project-dir] [-- claude args...]" >&2
      echo "" >&2
      echo "  project-dir defaults to the current directory ('.')." >&2
      echo "  Anything after '--' is passed straight to claude." >&2
      echo "" >&2
      echo "  A project gets ONE sandbox: if it is already running, this joins" >&2
      echo "  it rather than creating a second, isolated namespace." >&2
      echo "" >&2
      echo "  --shell     Drop into bash instead of launching claude" >&2
      echo "  --tmux      Run the agent inside a tmux session (prefix Ctrl-a; needed for agent teams)" >&2
      echo "  --gh-token  Forward GH_TOKEN/GITHUB_TOKEN env vars into sandbox" >&2
      echo "  --enter     Open a shell INSIDE this project's running sandbox," >&2
      echo "              to inspect it live; fails if none is running" >&2
      echo "  --new       Force a fresh, isolated sandbox instead of joining" >&2
      echo "  --stop      Terminate this project's sandbox" >&2
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shell)    shell_mode=true; shift ;;
        --tmux)     tmux_mode=true; shift ;;
        --gh-token) gh_token=true; shift ;;
        --enter)    enter_mode=true; shift ;;
        --stop)     stop_mode=true; shift ;;
        --new)      new_mode=true; shift ;;
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

    # A project gets one sandbox. The registry records the pid of the payload
    # process plus its namespace inodes: the pid is the join handle, and the
    # inodes validate it, because pids are recycled and a stale entry would
    # otherwise name an unrelated process. Written from INSIDE the sandbox (see
    # the register wrapper below) — there is no pid-namespace unshare, so the
    # pid is the same on both sides, and self-registration names the payload
    # rather than bwrap's intermediate process, whose root is the newroot/oldroot
    # staging tree rather than the sandbox root.
    ns_file="$state_dir/ns"
    live_pid=""
    reg_started=""
    if [[ -f "$ns_file" ]]; then
      reg_pid=""; reg_mnt=""; reg_user=""
      while IFS='=' read -r reg_k reg_v; do
        case "$reg_k" in
          pid)     reg_pid="$reg_v" ;;
          mnt)     reg_mnt="$reg_v" ;;
          user)    reg_user="$reg_v" ;;
          started) reg_started="$reg_v" ;;
        esac
      done < "$ns_file"
      if [[ -n "$reg_pid" ]] \
         && [[ "$(readlink "/proc/$reg_pid/ns/mnt" 2>/dev/null)" == "$reg_mnt" ]] \
         && [[ "$(readlink "/proc/$reg_pid/ns/user" 2>/dev/null)" == "$reg_user" ]]; then
        live_pid="$reg_pid"
      else
        rm -f "$ns_file"   # stale: pid gone, or recycled onto another process
      fi
    fi

    if [[ "$stop_mode" == true ]]; then
      if [[ -n "$live_pid" ]]; then
        echo "Stopping sandbox for $project_dir (pid $live_pid)" >&2
        kill "$live_pid" 2>/dev/null || true
        rm -f "$ns_file"
      else
        echo "No live sandbox for $project_dir" >&2
      fi
      exit 0
    fi

    if [[ "$enter_mode" == true ]]; then
      if [[ -z "$live_pid" ]]; then
        echo "Error: no live sandbox for $project_dir" >&2
        echo "  start one with: claude-sandbox $project_dir" >&2
        exit 1
      fi
      if [[ "$tmux_mode" != true ]]; then
        shell_mode=true
      fi
    fi

    sandbox_notice=${lib.escapeShellArg (spec.sandboxNotice "bubblewrap")}"${spec.persistenceNotice "$project_dir"}"

    # X11 display forwarding
    x11_args=()
    if [[ -n "''${DISPLAY:-}" ]] && [[ "$DISPLAY" == *:* ]]; then
      display_nr="''${DISPLAY/#*:}"
      display_nr="''${display_nr/%.*}"
      local_socket="/tmp/.X11-unix/X$display_nr"
      x11_args+=(--tmpfs /tmp/.X11-unix)
      x11_args+=(--ro-bind-try "$local_socket" "$local_socket")
    fi

    # Xauthority forwarding
    xauth_args=()
    if [[ -n "''${XAUTHORITY:-}" ]] && [[ -e "$XAUTHORITY" ]]; then
      xauth_args+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY")
    fi

    # Wayland forwarding
    wayland_args=()
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      wayland_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      if [[ -e "$wayland_socket" ]]; then
        wayland_args+=(--ro-bind "$wayland_socket" "$wayland_socket")
      fi
    fi

    # D-Bus system bus
    dbus_args=()
    if [[ -S /run/dbus/system_bus_socket ]]; then
      dbus_args+=(--ro-bind /run/dbus/system_bus_socket /run/dbus/system_bus_socket)
    fi

    # D-Bus session bus forwarding.
    # Needed for Secret Service API (gnome-keyring) so `gh auth status` works.
    # Chromium is isolated from the session bus via its wrapper (env -u
    # DBUS_SESSION_BUS_ADDRESS in chromium.nix) to prevent org.chromium.Chromium
    # singleton collisions across sandboxes.
    dbus_session_args=()
    if [[ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
      case "$DBUS_SESSION_BUS_ADDRESS" in
        unix:path=*)
          dbus_session_socket="''${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
          dbus_session_socket="''${dbus_session_socket%%;*}"
          if [[ -S "$dbus_session_socket" ]]; then
            dbus_session_args+=(--ro-bind "$dbus_session_socket" "$dbus_session_socket")
          fi
          ;;
      esac
      # Abstract sockets and other transports work without bind-mount
      # since bwrap shares the host network namespace.
      env_args+=(--setenv DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS")
    fi

    # DRI (GPU) forwarding for Chromium hardware acceleration
    dri_args=()
    if [[ -d /dev/dri ]]; then
      dri_args+=(--dev-bind /dev/dri /dev/dri)
    fi

    # Nested virt: pass the host KVM device through so a VM started inside
    # this sandbox runs on KVM. Guarded on the node existing — on hosts
    # without KVM this variant behaves exactly like the plain sandbox.
    kvm_args=()
    ${lib.optionalString kvm ''
      if [[ -c /dev/kvm ]]; then
        kvm_args+=(--dev-bind /dev/kvm /dev/kvm)
      else
        echo "warning: /dev/kvm not present on this host; VMs will fall back to TCG" >&2
      fi
    ''}

    # OpenGL/Vulkan driver forwarding (NixOS puts drivers in /run/opengl-driver)
    gpu_args=()
    if [[ -d /run/opengl-driver ]]; then
      gpu_args+=(--ro-bind /run/opengl-driver /run/opengl-driver)
    fi

    # Audio forwarding (PipeWire and PulseAudio)
    audio_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      # PipeWire
      if [[ -e "$XDG_RUNTIME_DIR/pipewire-0" ]]; then
        audio_args+=(--ro-bind "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0")
      fi
      # PulseAudio
      if [[ -e "$XDG_RUNTIME_DIR/pulse/native" ]]; then
        audio_args+=(--ro-bind "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse")
      fi
    fi

    # Keyring socket forwarding (gnome-keyring, KDE wallet)
    keyring_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]] && [[ -d "$XDG_RUNTIME_DIR/keyring" ]]; then
      keyring_args+=(--ro-bind "$XDG_RUNTIME_DIR/keyring" "$XDG_RUNTIME_DIR/keyring")
    fi

    # Determine sandbox home directory
    sandbox_home="$HOME"

    # Prepare XDG_RUNTIME_DIR bind args (needs --dir before bind since /run is tmpfs)
    xdg_runtime_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      xdg_runtime_args+=(--dir "$XDG_RUNTIME_DIR")
    fi

    # Claude auth and config persistence.
    # Bind ~/.claude (login token in .credentials.json, settings.json permissions);
    # it's a directory, so the bind source is stable.
    # ~/.claude.json is NOT bind-mounted: claude-code rewrites it via atomic
    # rename, so binding the live file races with a host session and aborts
    # the launch. Instead it is seeded by COPY: the file is opened on fd 11
    # (pinning a consistent snapshot even mid-rename) and bwrap's --file
    # writes it as a regular file in the tmpfs HOME. This carries the
    # oauthAccount/onboarding state (no login prompt per sandbox) while
    # sandbox writes still never touch host global state.
    claude_auth_args=()
    host_claude_dir="''${HOME}/.claude"
    mkdir -p "$host_claude_dir"
    claude_auth_args+=(--bind "$host_claude_dir" "$sandbox_home/.claude")
    if [[ -f "''${HOME}/.claude.json" ]]; then
      exec 11< "''${HOME}/.claude.json"
      claude_auth_args+=(--perms 0600 --file 11 "$sandbox_home/.claude.json")
    fi

    # omp ("oh my pi") config + auth persistence. Same shape as the ~/.claude
    # bind above: whole directory, rw. The snippet guarantees the host dir
    # (and agent/config.yml inside it) exists before the bind, so no --bind-try
    # and no fd/--file trick — that exists only because ~/.claude.json is a
    # single file racing atomic renames on the host; ~/.omp is a directory.
    omp_args=()
    ${spec.ompConfigSnippet}
    omp_args+=(--bind "$HOME/.omp" "$sandbox_home/.omp")

    # Per-project Chromium profile, keyed on a path unique to this project so
    # concurrent sandboxes get distinct instances. Lives in the state dir, not
    # the project dir — a browser profile inside a repo is untracked junk at
    # best and committed cookies at worst.
    # /tmp is a per-project directory under the HOST /tmp, bind-mounted in.
    # It used to be a fresh tmpfs, so anything written there vanished when the
    # sandbox exited. Living under the host /tmp rather than the state dir is
    # deliberate: it still self-cleans on host reboot, which is what a temp
    # directory should do, and it is short enough to reach from a host shell.
    # Keyed like the state dir, so projects cannot collide, and 0700 so other
    # users on the host cannot read it.
    sandbox_tmp="/tmp/claude-sandbox/$sd_base-$sd_hash"
    mkdir -p "$sandbox_tmp"
    chmod 700 "$sandbox_tmp"
    ln -sfn "$sandbox_tmp" "$state_dir/tmp"   # discoverable from the state dir

    chromium_profile="$state_dir/chromium"
    mkdir -p "$chromium_profile"

    # Persistent ~/.local. `claude doctor` wants ~/.local/bin on PATH, and with
    # pip shipped, `pip install --user` / pipx / npm -g land console scripts
    # there. bin/ alone is not enough: pip splits a --user install across bin/
    # and lib/pythonX.Y/site-packages, so persisting only bin/ leaves scripts
    # whose libraries vanished — a run-time failure rather than an install-time
    # one. Hence bin, lib and share.
    #
    # They are bound individually rather than binding ~/.local wholesale,
    # because the state dir itself lives at ~/.local/state/... — a bind over
    # ~/.local would shadow it and break the state dir mount underneath.
    mkdir -p "$state_dir/local"/{bin,lib,share}

    # tmux config and socket. The socket sits on a host-visible bind mount by
    # design: a Unix socket is a filesystem object and the connecting client
    # needs no namespace membership, so you can attach to the live claude UI
    # from another terminal with the sandbox's own tmux binary:
    #   ${sandboxPath}/bin/tmux -S <state_dir>/tmux.sock attach
    # Use that binary, not the host's, or the client/server protocol versions
    # may disagree. /nix/store is shared, so it is the same file.
    tmux_conf="$state_dir/tmux.conf"
    tmux_sock="$state_dir/tmux.sock"
    project_name="$(basename "$project_dir")"
    tmux_session="sandbox:$project_name"
    # Seeded when missing, and reseeded over a pre-Ctrl-a seed (older
    # projects), so existing sandboxes pick up the prefix without clobbering
    # a config that already has it.
    if [[ ! -f "$tmux_conf" ]] || ! grep -q "set -g prefix C-a" "$tmux_conf"; then
      cat > "$tmux_conf" << 'TMUXCONF'
# Sandbox tmux config — edit freely, persists across sandbox restarts
set -g prefix C-a
bind C-a send-prefix
unbind C-b
set -g mouse on
set -g default-terminal "tmux-256color"
set -g status-left "[#S] "
set -g status-left-length 40
set -g status-style "bg=colour208,fg=colour16,bold"
set -g status-left-style "bg=colour166,fg=colour255,bold"
TMUXCONF
    fi

    # Git and SSH forwarding (read-only)
    git_args=()
    if [[ -f "$HOME/.gitconfig" ]]; then
      git_args+=(--ro-bind "$HOME/.gitconfig" "$sandbox_home/.gitconfig")
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      git_args+=(--dir "$sandbox_home/.config/git")
      git_args+=(--ro-bind "$HOME/.config/git" "$sandbox_home/.config/git")
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      git_args+=(--ro-bind "$HOME/.ssh" "$sandbox_home/.ssh")
    fi
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]] && [[ -e "$SSH_AUTH_SOCK" ]]; then
      git_args+=(--ro-bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
    fi

    # GitHub CLI config (always mounted, like gitconfig)
    gh_args=()
    if [[ -d "''${HOME}/.config/gh" ]]; then
      gh_args+=(--dir "$sandbox_home/.config/gh")
      gh_args+=(--ro-bind "''${HOME}/.config/gh" "$sandbox_home/.config/gh")
    fi

    # Conditional env vars (only set when non-empty on host)
    env_args=()
    if [[ -n "''${DISPLAY:-}" ]]; then
      env_args+=(--setenv DISPLAY "$DISPLAY")
    fi
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
      env_args+=(--setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY")
    fi
    if [[ -n "''${XAUTHORITY:-}" ]]; then
      env_args+=(--setenv XAUTHORITY "$XAUTHORITY")
    fi
    # DBUS_SESSION_BUS_ADDRESS forwarded above (session bus section)
    if [[ "$gh_token" == true ]]; then
      if [[ -n "''${GH_TOKEN:-}" ]]; then
        env_args+=(--setenv GH_TOKEN "$GH_TOKEN")
      fi
      if [[ -n "''${GITHUB_TOKEN:-}" ]]; then
        env_args+=(--setenv GITHUB_TOKEN "$GITHUB_TOKEN")
      fi
    fi
    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      env_args+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")
    fi
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]]; then
      env_args+=(--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK")
    fi
    if [[ -n "''${LANG:-}" ]]; then
      env_args+=(--setenv LANG "$LANG")
    fi
    if [[ -n "''${LC_ALL:-}" ]]; then
      env_args+=(--setenv LC_ALL "$LC_ALL")
    fi

    # Select entrypoint
    if [[ "$shell_mode" == true ]]; then
      entrypoint=(bash)
    elif [[ "$tmux_mode" == true ]]; then
      entrypoint=(tmux -S "$tmux_sock" -f "$tmux_conf" new-session -s "$tmux_session" -- omp --append-system-prompt "$sandbox_notice" "''${claude_args[@]}")
    else
      entrypoint=(omp --append-system-prompt "$sandbox_notice" "''${claude_args[@]}")
    fi

    # Join an existing sandbox rather than creating a second namespace.
    # nsenter handles what a hand-rolled setns cannot: it opens every namespace
    # fd before joining any (credentials change on entering the user namespace,
    # after which /proc/<pid>/ns lookups fail), and --root reattaches the root
    # directory, without which every path resolves ENOENT.
    if [[ -n "$live_pid" ]] && [[ "$new_mode" != true ]]; then
      echo "Joining live sandbox for $project_dir (pid $live_pid, started $reg_started)" >&2
      # nsenter inherits OUR environment, which is the host's — the joined shell
      # would get the host PATH and HOME and none of the sandbox's setenv work.
      # Replay the payload's own environment instead, read from /proc. TERM is
      # reapplied afterwards so it reflects the terminal doing the joining.
      mapfile -d "" -t sandbox_env < "/proc/$live_pid/environ"
      # --preserve-credentials is required, not optional: bwrap denies setgroups
      # when setting up its unprivileged uid_map, so nsenter's default attempt
      # to set uid/gid/groups fails with EPERM.
      #
      # Do NOT use --wd. It leaves the cwd unreachable from the chroot root
      # nsenter installs, so getcwd(2) fails ENOENT while /proc/self/cwd still
      # resolves — which broke every bun single-file executable (claude
      # included), since bun walks ".." to reconstruct the cwd at startup. It
      # surfaced only as an opaque "Bun could not find a file". cd-ing after
      # entry resolves the path against the new root, so the cwd is reachable.
      # shellcheck disable=SC2016  # deliberate: runs in the joined shell, not here
      join_cmd='cd "$1" || exit 1; shift; exec "$@"'
      exec nsenter --target "$live_pid" --user --mount --root --preserve-credentials \
        -- env -i "''${sandbox_env[@]}" TERM="''${TERM:-xterm-256color}" \
        bash -c "$join_cmd" bash "$project_dir" "''${entrypoint[@]}"
    fi

    # Founding a new sandbox: the payload registers itself once it is inside,
    # so the recorded pid and inodes describe the namespace we actually want to
    # be joinable. "$@" carries the real entrypoint through the wrapper.
    # A --new sandbox must NOT register: it is explicitly an extra, isolated
    # namespace, and registering would hijack the singleton slot from the
    # sandbox already running for this project, which would then become
    # undiscoverable once the --new one exited.
    if [[ "$new_mode" != true ]]; then
      # shellcheck disable=SC2016  # deliberate: expands inside the sandbox, not here
      register_cmd='printf "pid=%s\nmnt=%s\nuser=%s\nstarted=%s\n" "$$" "$(readlink /proc/self/ns/mnt)" "$(readlink /proc/self/ns/user)" "$(date -Is)" > "$CLAUDE_SANDBOX_STATE_DIR/ns"; exec "$@"'
      entrypoint=(bash -c "$register_cmd" claude-sandbox "''${entrypoint[@]}")
    fi

    # No --die-with-parent: under singleton semantics the sandbox outlives the
    # terminal that founded it, or closing that terminal would tear the ground
    # out from under a shell joined from another one. Orphans are reaped by the
    # staleness check above, or explicitly via --stop.
    exec bwrap \
      --proc /proc \
      --dev /dev \
      --dev-bind /dev/shm /dev/shm \
      "''${dri_args[@]}" \
      "''${kvm_args[@]}" \
      --ro-bind /nix/store /nix/store \
      --ro-bind-try /nix/var/nix/db /nix/var/nix/db \
      --bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
      --ro-bind-try /run/current-system/sw /run/current-system/sw \
      --bind "$sandbox_tmp" /tmp \
      --tmpfs /run \
      "''${xdg_runtime_args[@]}" \
      --dir /run/dbus \
      "''${gpu_args[@]}" \
      --tmpfs /home \
      --dir "$sandbox_home" \
      --dir "$sandbox_home/.config" \
      "''${claude_auth_args[@]}" \
      "''${omp_args[@]}" \
      "''${git_args[@]}" \
      "''${gh_args[@]}" \
      --bind "$project_dir" "$project_dir" \
      --bind "$state_dir" "$state_dir" \
      --bind "$state_dir/local/bin" "$sandbox_home/.local/bin" \
      --bind "$state_dir/local/lib" "$sandbox_home/.local/lib" \
      --bind "$state_dir/local/share" "$sandbox_home/.local/share" \
      ${lib.concatMapStringsSep " \\\n  " (p: "--ro-bind-try ${p} ${p}") (spec.hostEtcPaths ++ spec.hostEtcPathsBwrapOnly)} \
      --dir /etc/chromium \
      --dir /etc/chromium/policies \
      --dir /etc/chromium/policies/managed \
      --ro-bind ${chromiumSandbox.extensionPolicy} /etc/chromium/policies/managed/default.json \
      --dir /bin \
      --symlink "${sandboxPath}/bin/bash" /bin/bash \
      --symlink "${sandboxPath}/bin/bash" /bin/sh \
      --dir /usr/bin \
      --symlink "${sandboxPath}/bin/bash" /usr/bin/bash \
      --ro-bind-try /usr/bin/env /usr/bin/env \
      --dir /lib64 \
      --symlink "${nix-ld}/libexec/nix-ld" /lib64/${spec.ldName} \
      --dir /lib \
      --symlink "${nix-ld}/libexec/nix-ld" /lib/${spec.ldName} \
      "''${x11_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      "''${dbus_session_args[@]}" \
      "''${audio_args[@]}" \
      "''${keyring_args[@]}" \
      "''${env_args[@]}" \
      --setenv HOME "$sandbox_home" \
      --setenv CLAUDE_SANDBOX 1 \
      --setenv CLAUDE_SANDBOX_BACKEND bubblewrap \
      --setenv CHROMIUM_USER_DATA_DIR "$chromium_profile" \
      --setenv CLAUDE_SANDBOX_STATE_DIR "$state_dir" \
      --setenv NIX_LD "${spec.realLoader}" \
      --setenv NIX_LD_LIBRARY_PATH "${lib.makeLibraryPath spec.nixLdLibraries}" \
      --setenv PATH "${sandboxPath}/bin:$sandbox_home/.local/bin" \
      --setenv TERM "''${TERM:-xterm-256color}" \
      --setenv NIX_REMOTE daemon \
      --setenv XDG_RUNTIME_DIR "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
      --setenv XDG_CONFIG_HOME "$sandbox_home/.config" \
      ${networkFlags} \
      --chdir "$project_dir" \
      "''${entrypoint[@]}"
  '';
}
