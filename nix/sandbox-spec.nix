# Sandbox specification — single source of truth for WHAT every sandbox needs.
# Each backend (bubblewrap, container, VM) implements HOW to deliver it.
#
# Programmatic fields (packages, chromeExtensionIds, hostEtcPaths) are consumed
# directly by backends. Complex mechanisms (dotfile mounts, sockets, env vars)
# stay as backend-specific code — see the documented checklist below.
{ pkgs }:
let
  # omp ("oh my pi", github:can1357/oh-my-pi) agent settings, seeded host-side
  # into ~/.omp/agent/config.yml ONLY when that file is missing. omp takes an
  # advisory lock on the file and rewrites it atomically at runtime (/settings
  # changes, onboarding), and its lock backend may drop an flock sidecar next
  # to it — so it must stay a writable regular file inside a writable
  # directory, never a store symlink or a read-only share. Upstream's home
  # manager module copies it into place for exactly this reason; we seed the
  # same way (see ompConfigSnippet) and share the whole ~/.omp directory rw.
  # formats.yaml matches upstream's own generator.
  ompSettings = { startup.quiet = true; };  # skip the startup banner
  ompConfigFile = (pkgs.formats.yaml { }).generate "omp-config.yml" ompSettings;
in
{
  # --- PROGRAMMATIC: consumed directly by backends ---

  # Core packages available inside every sandbox.
  # Chromium is intentionally excluded: bwrap uses chromiumSandbox wrapper,
  # container/VM use stock chromium. Each backend adds it separately.
  packages = with pkgs; [
    claude-code
    omp  # "oh my pi" (github:can1357/oh-my-pi) — a terminal AI coding agent,
         # an alternative to claude-code. PATH-only: no launcher integration,
         # run it from a shell inside the sandbox. Config + auth persist via
         # the shared host ~/.omp (see ompConfigSnippet and the checklist).
    git
    gh
    openssh
    nodejs
    bun  # some claude-code plugin hooks use #!/usr/bin/env bun
    # claude-code's security-guidance SessionStart hook needs a Python 3
    # interpreter. pip is bundled because the bare nixpkgs python3 has no
    # pip/ensurepip, so `python3 -m pip` and `python3 -m venv` both failed.
    (python3.withPackages (ps: [ ps.pip ]))
    tmux
    coreutils
    bash
    nix
    xclip  # claude-code's /copy shells out to a clipboard binary; reaches the
           # host X CLIPBOARD via the forwarded DISPLAY/X socket/Xauthority

    # Standard userland. coreutils provides NONE of grep/sed/awk/find, and
    # claude-code masks that in its own shell by injecting `grep` and `find` as
    # bash *functions* (ugrep/bfs wrappers around its binary). Those functions
    # do not exist in subprocesses, so scripts, Makefiles and `sh -c` broke on
    # missing tools while interactive use looked fine. Ship the real binaries.
    gnugrep
    gnused
    gawk
    findutils
    diffutils
    patch
    ripgrep
    fd
    jq
    less
    file
    which
    bc

    # Archives / compression
    gnutar
    gzip
    bzip2
    xz
    zstd
    zip
    unzip

    # Network
    curl
    wget
    rsync

    # Build / process inspection / editing (--shell mode is a real shell)
    gnumake
    procps
    psmisc
    lsof
    htop
    tree
    vim
    util-linux  # nsenter joins a running sandbox's namespaces; also lsns, findmnt
    strace      # the only practical way to see which file an opaque ENOENT means

    # Assumed by claude-code plugins and hooks. Grounded in a scan of
    # ~/.claude/plugins for external command references, not guesswork: uv
    # appeared 57 times, jq 65, shellcheck 10, shfmt 8. A missing one of these
    # is a "command not found" inside someone else's script.
    uv          # also the answer to nixpkgs python: PEP 668 marks it externally
                # managed AND user site-packages are disabled, so `pip --user`
                # cannot work at all. uv manages its own venvs and installs into
                # ~/.local, which the state dir now persists.
    shellcheck
    shfmt
    delta       # many gitconfigs set core.pager=delta; git output breaks without it
    just
    graphviz    # dot
    parallel
    gnupg       # git commit -S and signed tags fail without it
    openssl
    sqlite
    yq-go       # the YAML counterpart to jq

    # C toolchain. nix-ld lets prebuilt native binaries RUN, but an npm install
    # with no prebuilt artifact falls back to node-gyp, which has to compile.
    gcc
    binutils
    pkg-config

    # Document, image and data conversion
    imagemagick
    pandoc
    poppler-utils  # pdftotext

    # Network diagnostics
    dnsutils    # dig
    iputils     # ping
    netcat-gnu
    socat

    # Development workflow
    direnv
    entr
    watchexec
    hyperfine
    tokei
    cloc
    age
    sops
    nano        # some tools default EDITOR=nano and hard-fail when it is absent
  ];

  # nix-ld: let unpatched, dynamically-linked binaries run.
  #
  # Prebuilt npm native modules (.node), pip wheels with C extensions, and
  # esbuild/ruff/uv-class tools are all built against the FHS loader and fail
  # at exec with a "No such file or directory" that names a file which plainly
  # exists. Claude Code plugins hit this whenever they fetch a prebuilt binary.
  #
  # Backends must set BOTH env vars to store paths. The host's values leak into
  # the sandbox (bwrap does not clear the environment) and point into
  # /run/current-system, which is a tmpfs here — so nix-ld would advertise
  # itself as available and then fail on a dangling NIX_LD.
  ldName = baseNameOf pkgs.stdenv.cc.bintools.dynamicLinker;
  realLoader = pkgs.stdenv.cc.bintools.dynamicLinker;

  nixLdLibraries = with pkgs; [
    stdenv.cc.cc.lib  # libstdc++ / libgcc_s — the one most binaries need
    zlib
    openssl
    curl
    expat
    sqlite
    icu
    libxml2
    libuuid
  ];

  # Chrome extensions force-installed via managed policy.
  chromeExtensionIds = [
    "fcoeoabgfenejglbffodgkkbkcdhcgfn"  # Claude in Chrome
  ];

  # Notice appended to every sandboxed claude session's system prompt
  # (via `claude --append-system-prompt`) so the agent knows it is sandboxed
  # and must not treat sandbox-local observations as facts about the host.
  # `backend` is the backend name (bubblewrap / container / vm).
  sandboxNotice = backend:
    "You are running inside an isolated ${backend} sandbox created by " +
    "claude-code-nix-sandbox. The host machine's filesystem, PATH, " +
    "environment, and installed tools are NOT visible from inside this " +
    "sandbox: any command you run here (command -v, ls, env, package or " +
    "tool checks) reflects only the sandbox, never the host. Do not infer " +
    "host state from commands run here; if you need a fact about the host, " +
    "ask the user. Only the current project directory and explicitly " +
    "forwarded dotfiles are shared with the host.";

  # Second half of the notice, appended by each backend once the project
  # directory is resolved. `projectDirRef` is a SHELL EXPANSION (e.g.
  # "$project_dir"), not a literal path, because the persistent location is
  # only known at launch — so backends must place this inside bash double
  # quotes, unlike sandboxNotice which is escapeShellArg-quoted. Keep the text
  # free of double quotes, backticks and any other dollar sign.
  persistenceNotice = projectDirRef:
    " Project work must be created and saved under ${projectDirRef}, which is " +
    "shared with the host and persists across sandbox restarts. A few paths " +
    "under the home directory are also bind-mounted and persistent — sandbox " +
    "state such as the browser profile and .local, where tools you install " +
    "there land (use a venv or --prefix for python: this interpreter disables " +
    "user site-packages, so pip --user cannot work). Those are not part of " +
    "the project and must never " +
    "hold project work. Everything else, including the rest of the home " +
    "directory, /tmp and /run, is an ephemeral tmpfs that is DISCARDED " +
    "without warning when the sandbox exits. Never create a new project, " +
    "repository or output file outside ${projectDirRef}.";

  # Per-project persistent state, kept OUTSIDE the project directory so it is
  # never committed by accident (a chromium profile in a repo would leak
  # cookies and browsing state; .tmux/tmux.conf has been committed before).
  #
  # Directory name is <basename>-<sha256(path + "\n")[:12]>: the basename is a
  # human hint, the hash restores injectivity, which a plain slash->hyphen
  # mangle lacks (/a/b-c and /a-b/c both collapse to -a-b-c). The full path is
  # stored in a `path` file, which doubles as a collision detector — the same
  # trick direnv uses for its allow files (rc.go:386).
  #
  # Emitted as a shell snippet rather than a path because the project dir is
  # only known at launch. Requires a resolved $project_dir; sets $state_root
  # and $state_dir. Backends bind $state_dir at its real host path.
  #
  # Set $state_home first to override the home directory. The container backend
  # must: it runs under sudo, where $HOME is root's and the state would land in
  # /root instead of the user's home. That backend is also responsible for
  # chown-ing what this creates back to the real uid/gid.
  stateDirSnippet = ''
    sd_home="''${state_home:-$HOME}"
    state_root="''${XDG_STATE_HOME:-$sd_home/.local/state}/claude-code-nix-sandbox"
    mkdir -p "$state_root/projects"
    if [[ ! -f "$state_root/CACHEDIR.TAG" ]]; then
      printf '%s\n' \
        'Signature: 8a477f597d28d172789f06886806bc55' \
        '# Created by claude-code-nix-sandbox. Per-project sandbox state.' \
        '# Safe to delete when no sandbox is running.' \
        > "$state_root/CACHEDIR.TAG"
    fi
    sd_base="$(basename "$project_dir")"
    sd_base="''${sd_base//[^A-Za-z0-9._-]/-}"
    sd_hash="$(printf '%s\n' "$project_dir" | sha256sum | cut -c1-12)"
    state_dir="$state_root/projects/$sd_base-$sd_hash"
    mkdir -p "$state_dir"
    if [[ -f "$state_dir/path" ]]; then
      sd_recorded="$(cat "$state_dir/path")"
      if [[ "$sd_recorded" != "$project_dir" ]]; then
        echo "Error: state directory hash collision at $state_dir" >&2
        echo "  recorded: $sd_recorded" >&2
        echo "  current:  $project_dir" >&2
        exit 1
      fi
    else
      printf '%s\n' "$project_dir" > "$state_dir/path"
    fi
  '';

  # Host-side omp prep: guarantee ~/.omp/agent/config.yml exists as a writable
  # regular file BEFORE the sandbox starts, so the whole ~/.omp directory can
  # be shared rw (bind / virtiofs) and omp never sees a first-run without
  # config. Host-side in every backend, including the VM: the share exports
  # the host directory wholesale, so the file must exist on the host before
  # QEMU starts — one code path for all three backends.
  #
  # Seeds ONLY when missing: after first launch omp owns the file and its
  # runtime rewrites (see the ompSettings comment) must win over the declared
  # settings.
  #
  # Uses $HOME unless $omp_home is set. The container backend must set it: it
  # runs under sudo, where $HOME is root's. That backend is also responsible
  # for chown-ing what this creates back to the real uid/gid — same contract
  # as stateDirSnippet.
  ompConfigSnippet = ''
    omp_root="''${omp_home:-$HOME}/.omp"
    mkdir -p "$omp_root/agent"
    if [[ ! -e "$omp_root/agent/config.yml" ]]; then
      install -m 600 ${ompConfigFile} "$omp_root/agent/config.yml"
    fi
  '';

  # Host /etc paths forwarded into the sandbox (read-only).
  # Bubblewrap: --ro-bind-try per path
  # Container: for-loop --bind-ro per path
  # VM: N/A (own NixOS /etc)
  hostEtcPaths = [
    "/etc/resolv.conf"
    "/etc/hosts"
    "/etc/ssl"
    "/etc/ca-certificates"
    "/etc/pki"
    "/etc/fonts"
    "/etc/localtime"
    "/etc/zoneinfo"
    "/etc/locale.conf"
    "/etc/nix"
    "/etc/static"
    "/etc/nsswitch.conf"
  ];

  # Additional /etc paths only needed by bubblewrap.
  # Container and VM synthesize their own passwd/group/machine-id.
  hostEtcPathsBwrapOnly = [
    "/etc/passwd"
    "/etc/group"
    "/etc/machine-id"
  ];

  # --- DOCUMENTED CHECKLIST (backends implement explicitly) ---
  #
  # Dotfile mounts (mechanism differs per backend):
  #   ~/.claude                    — auth persistence (bind / virtiofs); login token in
  #                                  .credentials.json, permissions in settings.json
  #   ~/.claude.json               — seeded by COPY at launch, never bind-mounted
  #                                  (claude-code rewrites it via atomic rename, so a
  #                                  live bind races with a host session). It carries
  #                                  the oauthAccount/onboarding state — without the
  #                                  seed every sandbox prompts for login. Sandbox
  #                                  writes stay local, never touch the host file.
  #   ~/.omp                      — omp agent config + auth (rw bind / 9p, unlike
  #                                  the ro shares above: omp rewrites its config
  #                                  at runtime). agent/config.yml is seeded
  #                                  host-side ONLY when missing — it must stay a
  #                                  writable regular file in a writable dir
  #                                  (omp flock-locks and atomically rewrites
  #                                  it), never a store symlink or ro share.
  #                                  See ompConfigSnippet.
  #   ~/.gitconfig, ~/.config/git  — git config (ro-bind / virtiofs)
  #   ~/.ssh                       — SSH keys (ro-bind / virtiofs)
  #   ~/.config/gh                 — GitHub CLI config (ro-bind / virtiofs)
  #   .config/chromium             — per-project profile (bind / virtiofs)
  #
  # Sockets (mechanism differs per backend):
  #   X11 (/tmp/.X11-unix/Xn)     — display forwarding
  #   Xauthority                   — X11 auth cookie
  #   Wayland ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY)
  #   D-Bus system bus (/run/dbus/system_bus_socket) — direct bind
  #   D-Bus session bus — forwarded for Secret Service API (keyring);
  #     Chromium isolated via env -u DBUS_SESSION_BUS_ADDRESS in wrapper
  #   PipeWire / PulseAudio        — audio
  #   Keyring (gnome-keyring)      — secrets
  #   SSH agent ($SSH_AUTH_SOCK)   — SSH key forwarding
  #   Nix daemon socket            — nix operations inside sandbox
  #
  # Environment variables (mechanism differs per backend):
  #   DISPLAY, WAYLAND_DISPLAY, XAUTHORITY — display
  #   HOME, TERM, PATH                     — shell basics
  #   CHROMIUM_USER_DATA_DIR               — per-project profile
  #   NIX_REMOTE=daemon                    — nix daemon
  #   XDG_RUNTIME_DIR, XDG_CONFIG_HOME     — XDG dirs
  #   SSH_AUTH_SOCK                         — SSH agent
  #   ANTHROPIC_API_KEY                     — API auth
  #   GH_TOKEN, GITHUB_TOKEN               — GitHub auth (opt-in --gh-token)
  #   LANG, LC_ALL                          — locale
  #
  # Directories created inside sandbox:
  #   /tmp, /run, /home, $HOME, $HOME/.config
  #   /bin (bash, sh), /usr/bin (bash, env)
  #   /etc/chromium/policies/managed/      — extension policy
  #
  # GPU forwarding:
  #   /dev/dri, /dev/shm, /run/opengl-driver
}
