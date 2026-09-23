# microvm.nix VM backend for Claude Code + Chromium
#
# Usage: claude-sandbox-vm [--shell] [--stop] [--gh-token] [project-dir] [-- claude args...]
#        project-dir defaults to the current directory; args after -- go to claude
#
# The guest is a NixOS system built with microvm.nix
# (github:microvm-nix/microvm.nix) and run on QEMU: separate kernel, full
# hardware virtualization, the strongest isolation this project offers.
#
# Shape of the VM — each choice is explained at its site, the summary is:
#   * Headless. No QEMU display device and no host window: claude-code runs in
#     a tmux session on the serial console (ttyS0), Chromium renders into an
#     Xvfb display inside the guest.
#   * The guest has its own Nix store (an immutable image built by microvm.nix,
#     never the host's store — that can hold credentials) overlaid with a
#     per-project writable layer on a sparse volume, so the base is shared by
#     every VM of this build and only the delta is written per project.
#   * Every VM started from the same state root sits on one multicast socket
#     network and can reach the others (see SANDBOX LAN in the launcher).
{
  lib,
  pkgs,
  writeShellApplication,
  coreutils,
  socat,
  virtiofsd,
  microvm,
  nixos,
  # Toggle host network access (set false for isolated network)
  network ? true,
  # Guest RAM (MiB) and vCPU count — the DEFAULTS a launch uses. --mem/--cpus
  # or CLAUDE_SANDBOX_MEM/CLAUDE_SANDBOX_CPUS override per launch without a
  # rebuild: the QEMU argv pieces that size the guest are composed at launch
  # (see the launcher's guest-sizing block).
  mem ? 4096,
  vcpu ? 4,
  # Additional NixOS modules for the VM
  extraModules ? [ ],
}:

let
  spec = import ../sandbox-spec.nix { inherit pkgs; };

  # MAC of the user-mode (NAT) NIC. It only has to be unique within this VM's
  # own slirp network, so it is a build-time constant. The guest matches it by
  # MAC rather than by name: microvm.nix leaves interface naming to the guest,
  # and the sandbox LAN NIC is attached after it (position-dependent names
  # would break when `network = false` removes the first NIC).
  natMac = "02:00:00:00:00:02";

  guestModule = { pkgs, lib, ... }: {
    nixpkgs.config.allowUnfree = true;

    # ---------------------------------------------------------------- microvm
    microvm = {
      hypervisor = "qemu";
      inherit mem vcpu;

      # CPU model. microvm.nix's default (cpu = null) emits `-enable-kvm` plus
      # `-cpu host`: with no /dev/kvm QEMU then *exits* instead of falling back
      # to emulation (measured), which would make the backend require hardware
      # virtualization — the old qemu-vm.nix backend ran without it. Naming a
      # CPU model drops the `-enable-kvm` flag and leaves the accelerator list
      # at `kvm:tcg` (see machineOpts below), so KVM is still used whenever it
      # is available and TCG emulation is the fallback. `max` means "everything
      # the accelerator can do", the closest TCG-safe equivalent of `host`;
      # `-sgx` stays off because QEMU crashes with SGX on this machine type
      # (qemu#2142). On a KVM host that wants the literal host CPU, an
      # extraModules entry can set microvm.cpu = "host,+x2apic,-sgx".
      cpu = "max,-sgx";
      # Keep the slim KVM-capable build: setting `cpu` above would otherwise
      # switch to the full pkgs.qemu (every target), which the old backend did
      # not ship either.
      qemu.package = pkgs.qemu_kvm;

      # KSM and guest RAM. `mem-merge=on` (microvm.nix's x86_64 default, which
      # checks.vm-runner asserts) is what makes QEMU mark guest RAM
      # MADV_MERGEABLE. In *this* configuration that advice is ignored by the
      # kernel, and that is worth stating plainly rather than leaving as a
      # plausible-looking flag: MADV_MERGEABLE is a no-op on MAP_SHARED
      # mappings (mm/madvise.c kSM_madvise returns early for VM_SHARED |
      # VM_MAYSHARE), and the guest's RAM is shared because vhost-user virtiofs
      # requires a shared memfd backend (declared below). Measured on a running
      # VM: the 4 GiB mapping's VmFlags contain no `mg`, with or without
      # `merge=on` on the backend. So KSM cannot deduplicate this guest's RAM,
      # and enabling /sys/kernel/mm/ksm/run on the host would not change that.
      #
      # What does get deduplicated is the store: one immutable image per build
      # in the host's Nix store (storeOnDisk), shared by every VM, plus a
      # sparse per-project overlay — see the store comment below.
      #
      # The one live RAM lever is the balloon below (free-page reporting,
      # measured: 1.5 GiB returned to the host within ~20 s of the guest
      # freeing it). KSM in every direction is a measured dead end — host-side
      # (shared memfd RAM is unmergeable), guest-side (ksmd scanned zero pages
      # with registered mergeable VMAs, and no stock guest app marks pages
      # anyway) — see docs/src/backends/vm.md, "Memory".
      #
      # The microvm machine type proper: no display device, no PCI bus, no
      # legacy chipset — the smallest machine QEMU offers, at microvm.nix's
      # upstream machine options (acpi=on, pit=off). One hard consequence:
      # this configuration requires KVM. Under TCG the guest stalls in early
      # boot (no kvm-clock; measured on acpi=on with pit/pic/rtc combinations),
      # and acpi=off is no escape — without ACPI the machine instantiates only
      # 8 virtio-mmio transports and this guest needs ~15 (measured: the third
      # runtime share fails with "A 'virtio-bus' bus was found but is full").
      # The launcher fails fast without /dev/kvm; the sandbox-kvm package
      # binds the device through for nested use.
      qemu.machine = "microvm";

      # Our virtiofs devices are vhost-user, which is handed guest RAM over a
      # socket: the memory has to be a shared memfd. microvm.nix only emits
      # that object when it declares shares itself, and this configuration
      # declares none (the guest has its own store disk, and every other share
      # comes from the launcher) — so the LAUNCHER emits it at launch time
      # together with -numa node,memdev=mem and the -m/-smp overrides, sized
      # from --mem / CLAUDE_SANDBOX_MEM (default: the mem parameter). That
      # placement is what makes guest RAM and vCPUs reconfigurable per launch
      # without a rebuild: the extraArgsScript output lands last in QEMU's
      # argv, and its last-wins parsing overrides the build-time values
      # (measured via info numa / query-cpus-fast). Shared RAM is not
      # KSM-mergeable (see the KSM note above), so this also keeps KSM ruled
      # out for the guest.

      # QEMU arguments that can only be composed at launch: the virtiofs
      # devices for the runtime shares (their sources are the user's project,
      # home and a per-launch metadata dir) and the sandbox LAN NIC. microvm.nix takes shares/interfaces at build time, so
      # these ride the runtime hook instead: the launcher exports
      # CLAUDE_SANDBOX_VM_QEMU_ARGS and microvm.nix word-splits this script's
      # output into the hypervisor's argv.
      extraArgsScript = "${pkgs.writeShellScript "claude-vm-extra-args" ''
        printf '%s\n' "''${CLAUDE_SANDBOX_VM_QEMU_ARGS:-}"
      ''}";

      # QMP control socket (screendump, graceful shutdown). Relative to the
      # directory the runner is started from, which is the project state dir.
      socket = "qmp.sock";

      # Free-page reporting: the guest reports pages it has freed and the host
      # drops them (with deflate-on-oom so the balloon gives memory back when
      # the host is under pressure). This is the RAM reduction that still works
      # with vhost-user shared memory, unlike KSM — host-side merging is
      # blocked by the shared memfd, and the in-guest daemon measured zero
      # pages scanned — see the Memory section of docs/src/backends/vm.md.
      balloon = true;

      # User-mode (slirp) NIC: outbound NAT only. Without it the guest has no
      # NIC at all (microvm.nix attaches exactly the interfaces declared), and
      # networking.useDHCP below has been replaced by a MAC-matched
      # systemd-networkd unit so the sandbox LAN NIC is never touched by DHCP.
      interfaces = lib.optional network {
        type = "user";
        id = "nat";
        mac = natMac;
      };

      # The guest gets its OWN copy of the Nix store, built as an immutable
      # squashfs/erofs image and attached as a read-only virtio disk. The host
      # store is deliberately never shared: it can contain credentials (secret
      # values baked into other projects' store paths, fetched sources), and
      # this is the strongest-isolation backend — the guest must not be able to
      # read paths that belong to the host or to other sandboxes.
      #
      # This is microvm.nix's default (storeOnDisk), and it is also the
      # deduplication story: the image is a single content-addressed artifact
      # in the host's Nix store, shared by every VM built from this
      # configuration, and each project only writes its own delta (the
      # writable layer below). No per-VM copy of the base exists.
      storeOnDisk = true;

      # Left null on purpose: microvm.nix's writableStoreOverlay declares the
      # overlay as neededForBoot, so nixpkgs prefixes its lower/upper/work dirs
      # with /sysroot for the initrd — and the same fstab entry is then also
      # consumed in stage 2, which on this VM produced a *second*, read-only
      # overlay stacked on /nix/store that shadowed the writable one
      # (measured: two `overlay /nix/store` entries in /proc/mounts, writes
      # failing with EROFS). Instead /nix/store is a plain read-only erofs
      # mount — all the initrd needs to exec `init` — and the writable overlay
      # is mounted by nix-store-overlay.service below.
      writableStoreOverlay = null;

      # Per-project writable state, as sparse ext4 images named relative to the
      # state dir. Only what is actually written occupies space: this is the
      # "delta only" half of the storage model above. They persist across
      # restarts on purpose — a nix profile install or a pulled docker image
      # should not be redone every launch.
      volumes = [
        {
          image = "nix-store-overlay.img";
          mountPoint = "/nix/.rw-store";
          size = 10240;
        }
        {
          image = "docker.img";
          mountPoint = "/var/lib/docker";
          size = 10240;
        }
      ];
    };

    # microvm.nix mounts volumes at the default fstab pass, which runs e2fsck
    # over a freshly created 10 GiB image (no clean-unmount record yet) — a
    # full inode-table scan that cost ~1.5 minutes per volume under emulation
    # and delayed /var/lib/docker past every other boot step. ext4 replays its
    # journal from an unclean shutdown, so the check adds nothing here.
    fileSystems."/nix/.rw-store".noCheck = true;
    fileSystems."/var/lib/docker".noCheck = true;

    # This guest only ever sees virtio hardware: volumes are virtio-blk, the
    # store arrives over virtiofs, the console is an emulated 8250 UART, and
    # there is no SATA/USB/MD/DM anywhere. Dropping NixOS's default initrd
    # module set shrinks the initrd and cuts the module loading that dominates
    # early boot — the "narrow support window" this backend can afford, since
    # it only ever runs the current NixOS on the current kernel. ext4 must be
    # named explicitly: the writable store layer is an ext4 volume mounted
    # from the initrd, and it is no longer pulled in by the default set.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.kernelModules = [ "ext4" ];

    # microvm.optimize (on by default) narrows the kernel command line to a
    # single serial console — which is all this VM has. This list is mkForce'd
    # so it also replaces microvm's own parameters.
    #
    # The rest is speed over paranoia *inside* the guest, which is what this
    # backend is for: the isolation boundary is the hypervisor, not the guest
    # kernel, and everything in the sandbox is untrusted code by construction.
    #   mitigations=off     removes spectre/meltdown mitigations: the biggest
    #                       CPU win available, and the one real tradeoff here —
    #                       it weakens the guest kernel against exploits from
    #                       inside the sandbox. Remove it if that matters.
    #   nowatchdog, nmi_watchdog=0  the lockup detectors nobody reads in a VM
    #   random.trust_cpu=on entropy from the CPU instead of stalling on the
    #                       boot-time entropy pool
    #   audit=0             no audit subsystem (nothing uses it here)
    #   loglevel=3          keep warnings, drop the boot-time chatter
    boot.kernelParams = lib.mkForce [
      "mitigations=off"
      "nowatchdog"
      "nmi_watchdog=0"
      "random.trust_cpu=on"
      "audit=0"
      "loglevel=3"
    ];

    # Latest stable kernel: this backend only ever runs current NixOS, so there
    # is no reason to sit on the default (older) kernel.
    boot.kernelPackages = pkgs.linuxPackages_latest;

    # Kernel-side performance defaults for an agent + browser + docker
    # workload. Everything here is a documented default that costs something
    # somewhere else, not cargo cult:
    boot.kernel.sysctl = {
      # BBR + fair queueing: better throughput/latency on the NAT link than
      # cubic, which is what the guest mostly has for network.
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";
      "net.core.somaxconn" = 4096;
      "net.ipv4.tcp_fastopen" = 3;
      # File watching and descriptors: chromium, vite/watchman-class tooling and
      # docker all hit inotify limits that are far too low by default.
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 1024;
      "fs.file-max" = 2097152;
      # Memory behaviour: no swap exists in this guest, the root filesystem is
      # tmpfs, and huge mmap counts are normal for chromium/docker.
      "vm.swappiness" = 1;
      "vm.max_map_count" = 1048576;
      "vm.dirty_background_ratio" = 5;
      "vm.dirty_ratio" = 20;
    };

    # Guest mounts for the shares the launcher serves with one virtiofsd each.
    # Declared here (not through microvm.shares) because their sources exist
    # only at launch. Options mirror what microvm.nix generates for its own
    # virtiofs shares: the module load ordering matters for mounts that must
    # come up during boot.
    fileSystems = {
      "/project" = {
        device = "project_share";
        fsType = "virtiofs";
        options = [ "defaults" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/home/sandbox/.claude" = {
        device = "claude_auth";
        fsType = "virtiofs";
        options = [ "defaults" "nofail" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/home/sandbox/.omp" = {
        device = "omp_auth";
        fsType = "virtiofs";
        options = [ "defaults" "nofail" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/home/sandbox/.config/git" = {
        device = "git_config_dir";
        fsType = "virtiofs";
        options = [ "defaults" "ro" "nofail" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/home/sandbox/.config/gh" = {
        device = "gh_config_dir";
        fsType = "virtiofs";
        options = [ "defaults" "ro" "nofail" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/home/sandbox/.ssh" = {
        device = "ssh_dir";
        fsType = "virtiofs";
        options = [ "defaults" "ro" "nofail" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/mnt/meta" = {
        device = "claude_meta";
        fsType = "virtiofs";
        options = [ "defaults" "ro" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
      "/mnt/state" = {
        device = "state_dir";
        fsType = "virtiofs";
        options = [ "defaults" "nofail" "x-systemd.after=systemd-modules-load.service" ];
        noCheck = true;
      };
    };
    # Writable store. With writableStoreOverlay left null, microvm.nix mounts
    # the immutable erofs image directly and read-only at /nix/store, which is
    # all the initrd needs to exec `init`. This unit gives the guest a writable
    # store back: bind that read-only view at /nix/.ro-store as the lower layer,
    # and overlay the per-project volume (upper) on top. It runs before
    # multi-user.target, so nix-daemon, docker and the console all see a
    # writable store.
    systemd.services.nix-store-overlay = {
      description = "Overlay the writable store layer onto the immutable store image";
      wantedBy = [ "multi-user.target" ];
      before = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = "/nix/store /nix/.rw-store";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = [
          # mounts.nix creates these for a *declared* overlay; this one is
          # mounted by hand, so it has to make its own upper/work dirs. Overlayfs
          # refuses to mount if either is missing (measured: "failed to resolve
          # '/nix/.rw-store/store': -2").
          "${pkgs.coreutils}/bin/mkdir -p /nix/.rw-store/store /nix/.rw-store/work"
          "${pkgs.coreutils}/bin/mkdir -p /nix/.ro-store"
          "${pkgs.util-linux}/bin/mount --bind -o ro /nix/store /nix/.ro-store"
        ];
        ExecStart = "${pkgs.util-linux}/bin/mount -t overlay overlay -o lowerdir=/nix/.ro-store,upperdir=/nix/.rw-store/store,workdir=/nix/.rw-store/work /nix/store";
        ExecStop = [
          "${pkgs.util-linux}/bin/umount /nix/store"
          "${pkgs.util-linux}/bin/umount /nix/.ro-store"
        ];
      };
    };
    # Without writableStoreOverlay microvm.nix disables the daemon by default
    # (it only works against a writable store); nix builds and installs inside
    # the guest need it, and nix-store-overlay.service above provides the
    # writable store. mkForce because microvm.nix sets both with mkDefault.
    systemd.services.nix-daemon.enable = lib.mkForce true;
    systemd.sockets.nix-daemon.enable = lib.mkForce true;
    boot.kernelModules = [ "virtiofs" "overlay" "tcp_bbr" ];

    # ------------------------------------------------------------ sandbox LAN
    # The launcher attaches a second NIC on a multicast socket network shared
    # by every sandbox VM of this state root, with an address it allocates per
    # project at launch. Neither the address nor the interface name is known at
    # build time, so the guest applies the address by matching the MAC it was
    # given through the read-only metadata share.
    systemd.services.claude-sandbox-lan = {
      description = "Apply the sandbox LAN address";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-meta.mount" "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.iproute2 pkgs.gawk ];
      script = ''
        if [[ ! -f /mnt/meta/lan_ip || ! -f /mnt/meta/lan_mac ]]; then
          # Older launcher, or a VM started by hand: nothing to configure.
          exit 0
        fi
        lan_ip=$(cat /mnt/meta/lan_ip)
        lan_mac=$(cat /mnt/meta/lan_mac)
        iface=""
        for _ in $(seq 1 50); do
          iface=$(ip -o link show | awk -v mac="$lan_mac" 'index($0, mac) { print $2 }' | tr -d ':' | head -n1)
          [[ -n "$iface" ]] && break
          sleep 0.2
        done
        if [[ -z "$iface" ]]; then
          echo "claude-sandbox-lan: no interface with MAC $lan_mac" >&2
          exit 1
        fi
        ip addr replace "$lan_ip/24" dev "$iface"
        ip link set "$iface" up
      '';
    };

    # ---------------------------------------------------------------- display
    # Chromium needs an X display; the VM has no display hardware at all (no
    # VGA device, no host window), so the guest runs its own headless X server.
    # -ac matches how the other backends' displays are run: this is a
    # single-user sandbox, and it removes the X-cookie problem entirely (HOME
    # is remapped to the host path for the console session, which is not where
    # Xvfb would have written the cookie).
    systemd.services.claude-xvfb = {
      description = "Headless X server for the sandbox browser";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        User = "sandbox";
        Group = "users";
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 1;
        Environment = "HOME=/home/sandbox";
      };
      script = "exec ${pkgs.xvfb}/bin/Xvfb :0 -screen 0 1920x1080x24 -nolisten tcp -ac";
    };

    # Software rendering for Chromium (no GPU, no /dev/dri in the guest) and
    # the fonts services.xserver used to pull in before Xvfb replaced it.
    hardware.graphics.enable = true;
    fonts.enableDefaultPackages = true;

    # ---------------------------------------------------------------- console
    # Auto-login sandbox user on the serial console (the only console: the
    # microvm machine instantiates a single ISA serial on ttyS0).
    services.getty.autologinUser = "sandbox";

    # Set up environment for sandbox user's login shell
    environment.interactiveShellInit = ''
      # Serial-console sessions get the host-path and ~/.local setup; only the
      # primary console runs the entrypoint, and it must not re-bind an
      # already-bound project.
      if [[ "$(tty)" == /dev/ttyS0 ]]; then
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
          # Guard: a re-login on the console would stack a second bind-mount
          # on the same path.
          if ! mountpoint -q "$host_project"; then
            sudo mount --bind /project "$host_project"
          fi
        fi

        # Xvfb is a plain service, not a display manager, so nothing orders the
        # entrypoint after it: wait briefly for the socket rather than starting
        # claude against a display that is a few hundred milliseconds away.
        export DISPLAY=:0
        for ((i = 0; i < 50; i++)); do
          [[ -S /tmp/.X11-unix/X0 ]] && break
          sleep 0.1
        done

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

        # The entrypoint runs inside tmux, so detaching (Ctrl-a d) leaves the
        # agent running and a later console login reattaches to the same
        # session. The entrypoint file is a shell command line (written with
        # printf %q), hence `bash <file>`.
        if [[ "$(tty)" == /dev/ttyS0 && -f /mnt/meta/entrypoint ]]; then
          session=$(cat /mnt/meta/tmux_session)
          if [[ "$(cat /mnt/meta/entrypoint)" == bash ]]; then
            exec tmux -f /mnt/state/tmux.conf new-session -A -s "$session"
          else
            exec tmux -f /mnt/state/tmux.conf new-session -A -s "$session" "bash /mnt/meta/entrypoint"
          fi
        fi
      fi
    '';

    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };

    # Chromium writes its profile under $HOME/.config, and the console session
    # points $HOME/.config at /home/sandbox/.config (the git/gh shares are
    # mounted inside it). systemd creates those mount parents as root, so the
    # sandbox user could not create anything in that directory: Chromium died
    # with "Failed to create headless user data directory container" /
    # `mkdir("/home/sandbox/.config/chromium-headless") = EACCES` (measured via
    # strace in the guest). tmpfiles runs after local-fs, so this hands the
    # directory to the sandbox user without touching the mounts inside it.
    systemd.tmpfiles.rules = [
      "d /home/sandbox 0700 sandbox users -"
      "d /home/sandbox/.config 0700 sandbox users -"
    ];

    users.users.sandbox = {
      isNormalUser = true;
      home = "/home/sandbox";
      uid = 1000;
      extraGroups = [ "video" "audio" "wheel" "docker" ];
    };

    # Docker inside the VM (its state is the docker.img volume above).
    virtualisation.docker.enable = true;

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
      # networkd explicitly: the NAT NIC is configured below by MAC, and the
      # sandbox LAN NIC must stay untouched by any DHCP client.
      useNetworkd = true;
      useDHCP = false;
    };
    systemd.network.networks."10-nat" = lib.mkIf network {
      matchConfig.MACAddress = natMac;
      networkConfig.DHCP = "yes";
      # Boot must not wait on upstream connectivity: the console is the point,
      # and the sandbox LAN is link-local to this host.
      linkConfig.RequiredForOnline = "no";
    };

    # Chromium managed policy: force-install Claude in Chrome extension
    # (/etc/fonts/fonts.conf comes from fonts.enableDefaultPackages above; a
    # second definition here only produced a duplicate-entry warning.)
    environment.etc = {
      "chromium/policies/managed/default.json".text = builtins.toJSON {
        ExtensionInstallForcelist = spec.chromeExtensionIds;
      };
    };

    system.stateVersion = "24.11";
  };

  microvmSystem = nixos {
    imports = [ microvm.nixosModules.microvm guestModule ] ++ extraModules;
  };

  runner = microvmSystem.config.microvm.declaredRunner;
in
writeShellApplication {
  name = "claude-sandbox-vm";
  runtimeInputs = [ coreutils socat virtiofsd ];

  text = ''
    shell_mode=false
    stop_mode=false
    gh_token=false
    vm_mem=""
    vm_cpus=""
    project_dir="."
    agent_args=()

    usage() {
      echo "Usage: claude-sandbox-vm [OPTIONS] [project-dir] [-- agent args...]" >&2
      echo "" >&2
      echo "  project-dir defaults to the current directory ('.')." >&2
      echo "  Anything after '--' is passed straight to the agent (omp)." >&2
      echo "" >&2
      echo "  --mem MiB   Guest RAM in MiB (default ${toString mem}; env CLAUDE_SANDBOX_MEM)" >&2
      echo "  --cpus N    Guest vCPUs (default ${toString vcpu}; env CLAUDE_SANDBOX_CPUS)" >&2
      echo "  --shell     Drop into a tmux session with bash instead of launching omp" >&2
      echo "  --stop      Terminate this project's running VM" >&2
      echo "  --gh-token  Forward GH_TOKEN/GITHUB_TOKEN env vars into VM" >&2
      echo "" >&2
      echo "  The session runs omp; claude-code is installed and can be started" >&2
      echo "  from the shell. tmux prefix is Ctrl-a." >&2
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shell)    shell_mode=true; shift ;;
        --stop)     stop_mode=true; shift ;;
        --gh-token) gh_token=true; shift ;;
        --mem)      vm_mem="$2"; shift 2 ;;
        --cpus)     vm_cpus="$2"; shift 2 ;;
        --help|-h)  usage; exit 0 ;;
        --)         shift; agent_args=("$@"); break ;;
        -*)         echo "Unknown option: $1 (pass claude args after '--')" >&2; exit 1 ;;
        *)          project_dir="$1"; shift
                    if [[ "''${1:-}" == "--" ]]; then shift; fi
                    agent_args=("$@"); break ;;
      esac
    done

    project_dir="$(realpath "$project_dir")"
    if [[ ! -d "$project_dir" ]]; then
      echo "Error: $project_dir is not a directory" >&2
      exit 1
    fi

    ${spec.stateDirSnippet}

    # --stop: graceful QMP shutdown of this project's running VM (the runner's
    # cleanup then takes down its virtiofsds).
    if [[ "$stop_mode" == true ]]; then
      if [[ ! -S "$state_dir/qmp.sock" ]]; then
        echo "No running VM for $project_dir." >&2
        exit 0
      fi
      printf 'qmp_capabilities\nquit\n' | timeout 5 socat - "unix-connect:$state_dir/qmp.sock" >/dev/null 2>&1 || true
      for _ in $(seq 1 50); do
        timeout 1 socat -u /dev/null "unix-connect:$state_dir/qmp.sock" 2>/dev/null || break
        sleep 0.2
      done
      rm -f "$state_dir/qmp.sock"
      echo "VM stopped." >&2
      exit 0
    fi

    # The microvm machine (acpi=on) has no bootable timer under TCG emulation
    # and the acpi=off escape hatch caps virtio-mmio at 8 transports — this
    # guest needs ~15. So KVM is a hard requirement; fail fast instead of
    # hanging in early boot.
    if [[ ! -c /dev/kvm || ! -w /dev/kvm ]]; then
      echo "Error: /dev/kvm is not available — the VM backend requires KVM." >&2
      echo "  On a bare host: load kvm_amd/kvm_intel and check group membership." >&2
      echo "  Inside a sandbox: start it from 'nix build .#sandbox-kvm' (binds /dev/kvm)." >&2
      exit 1
    fi

    # Guest sizing: --mem/--cpus beat CLAUDE_SANDBOX_MEM/CLAUDE_SANDBOX_CPUS,
    # which beat the build-time defaults. Applies at VM start; a running VM
    # keeps its resources until it is stopped.
    mem_mib="''${vm_mem:-''${CLAUDE_SANDBOX_MEM:-${toString mem}}}"
    cpu_count="''${vm_cpus:-''${CLAUDE_SANDBOX_CPUS:-${toString vcpu}}}"
    if ! [[ "$mem_mib" =~ ^[0-9]+$ ]]; then
      echo "Error: --mem/CLAUDE_SANDBOX_MEM must be an integer (MiB), got: $mem_mib" >&2
      exit 1
    fi
    if [[ "$mem_mib" -eq 2048 ]]; then
      # QEMU hangs with exactly 2 GiB of guest RAM
      # (github:microvm-nix/microvm.nix#171) — reject it up front.
      echo "Error: 2048 MiB of guest RAM hangs QEMU; pick any other size." >&2
      exit 1
    fi
    if ! [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]]; then
      echo "Error: --cpus/CLAUDE_SANDBOX_CPUS must be a positive integer, got: $cpu_count" >&2
      exit 1
    fi

    # Persistent ~/.local, shared into the guest at /mnt/state and symlinked
    # into the reconstructed host home. The chromium profile is deliberately
    # NOT persisted here, unlike the other backends: this VM runs stock
    # chromium rather than the wrapper, so it ignores CHROMIUM_USER_DATA_DIR.
    mkdir -p "$state_dir/local"/{bin,lib,share}

    # tmux config for the console session: seeded when missing, and reseeded
    # over a pre-Ctrl-a seed (older projects), so existing sandboxes pick up
    # the prefix without clobbering a config that already has it. Ctrl-a is
    # the prefix (and C-a C-a sends a literal one); the stock C-b is unbound
    # so it reaches the agent instead.
    tmux_conf="$state_dir/tmux.conf"
    if [[ ! -f "$tmux_conf" ]] || ! grep -q "set -g prefix C-a" "$tmux_conf"; then
      cat > "$tmux_conf" << 'TMUXCONF'
# Sandbox tmux config — edit freely, persists across VM restarts
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

    # One VM per project: the QMP socket has a live listener only while a VM
    # is up, and two VMs for the same project would run against the same
    # store-overlay and docker volumes — corruption, not just confusion. A
    # socket file left behind by a killed VM has no listener, so probe it
    # before believing it (QEMU also unlinks stale sockets at bind).
    if [[ -S "$state_dir/qmp.sock" ]]; then
      if timeout 2 socat -u /dev/null "unix-connect:$state_dir/qmp.sock" 2>/dev/null; then
        echo "Error: a sandbox VM is already running for $project_dir" >&2
        echo "  stop it with: claude-sandbox-vm --stop $project_dir" >&2
        exit 1
      fi
      rm -f "$state_dir/qmp.sock"
    fi

    # ------------------------------------------------------------- SANDBOX LAN
    # Every VM started from this state root shares one Ethernet-like segment,
    # built from a QEMU multicast socket network: each VM opens a UDP socket
    # joined to the same group, and QEMU turns frames into datagrams (it sets
    # IP_MULTICAST_LOOP, so several VMs on one host do see each other). That is
    # the only unprivileged way to put VMs on a common L2 — a tap or bridge
    # needs root (the host module of microvm.nix, which this CLI does not use,
    # would need CAP_NET_ADMIN for the tap).
    #
    # The group and subnet are derived from the state root, so different users
    # (different state roots) get different segments instead of colliding over
    # the same 10.76.x.x addresses. The host itself is not a member of the
    # segment.
    #
    # An address is allocated once per project and kept: it is stable across
    # restarts (peers can hardcode it), and the mkdir is the allocation lock,
    # so two launchers racing cannot pick the same one. Nothing reclaims an
    # address — the space holds 253 projects per state root.
    lan_dir="$state_root/lan"
    mkdir -p "$lan_dir"
    lan_salt="$(printf '%s\n' "$state_root" | sha256sum | cut -c1-2)"
    lan_net=$(( 16#$lan_salt % 250 + 1 ))
    lan_group="230.0.0.$(( lan_net + 1 ))"
    if [[ -f "$state_dir/lan_ip" ]]; then
      lan_ip="$(cat "$state_dir/lan_ip")"
    else
      lan_ip=""
      for host in $(seq 2 254); do
        if mkdir "$lan_dir/$lan_net.$host" 2>/dev/null; then
          lan_ip="10.76.$lan_net.$host"
          printf '%s\n' "$lan_ip" > "$state_dir/lan_ip"
          printf '%s\n' "$project_dir" > "$lan_dir/$lan_net.$host/project"
          break
        fi
      done
      if [[ -z "$lan_ip" ]]; then
        echo "Error: no free address left in the sandbox LAN 10.76.$lan_net.0/24" >&2
        exit 1
      fi
    fi
    lan_host="''${lan_ip##*.}"
    # MAC derived from the address: unique per VM, and stable across restarts.
    # It has to be unique because the segment behaves like a hub.
    lan_mac="02:76:$(printf '%02x' "$lan_net"):$(printf '%02x' "$lan_host"):00:01"

    # The VM knows its own address; the agent should not have to guess it.
    # Built as three appends rather than one concatenated literal: the
    # persistence notice must sit inside double quotes (it contains a shell
    # expansion, $project_dir, and parentheses that are unquoted syntax), and
    # a single glued-together line silently loses one of the quotes.
    lan_notice=" This sandbox has a private network address on a segment shared with the other claude-sandbox VMs started from this machine: you are $lan_ip/24, and you can reach the other VMs (and they you) by their addresses. The host is not on that segment."
    sandbox_notice=${lib.escapeShellArg (spec.sandboxNotice "vm")}
    sandbox_notice+="''${lan_notice}"
    sandbox_notice+="${spec.persistenceNotice "$project_dir"}"

    # Clean up stale metadata dirs from previous runs of THIS project killed
    # with SIGKILL. The name is project-scoped deliberately: a global sweep of
    # /tmp/claude-vm-meta.* would delete the metadata dir a concurrently
    # starting sandbox for another project just created (observed: virtiofsd
    # then failed with "does not exist or is not a directory"). The
    # per-project volumes (nix store overlay, docker) are deliberately NOT
    # swept: they hold the delta on top of the shared store image.
    for stale in "/tmp/claude-vm-meta.$sd_hash".*/; do
      [[ -d "$stale" ]] || continue
      rm -rf "$stale"
    done

    # Create metadata directory (entrypoint + API key + LAN identity)
    meta_dir="$(mktemp -d "/tmp/claude-vm-meta.$sd_hash.XXXXXX")"

    # PIDs of the per-share virtiofsd daemons (populated by start_vfsd below);
    # the trap tears them down alongside the metadata dir, which holds their
    # sockets.
    vfsd_pids=()
    trap 'rm -rf "$meta_dir"; if [[ "''${#vfsd_pids[@]}" -gt 0 ]]; then kill "''${vfsd_pids[@]}" 2>/dev/null || true; fi' EXIT

    if [[ "$shell_mode" == true ]]; then
      echo "bash" > "$meta_dir/entrypoint"
      echo "shell" > "$meta_dir/tmux_session"
    else
      # omp is the default agent (claude-code is still installed and can be run
      # from the session's shell). Both take --append-system-prompt, so the
      # sandbox notice rides along either way.
      printf '%q ' omp --append-system-prompt "$sandbox_notice" "''${agent_args[@]}" > "$meta_dir/entrypoint"
      echo "omp" > "$meta_dir/tmux_session"
    fi

    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      echo "$ANTHROPIC_API_KEY" > "$meta_dir/apikey"
    fi

    # Pass host paths so VM can reconstruct them
    echo "$HOME" > "$meta_dir/host_home"
    echo "$project_dir" > "$meta_dir/host_project"
    echo "$lan_ip" > "$meta_dir/lan_ip"
    echo "$lan_mac" > "$meta_dir/lan_mac"

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
    # attached to the guest as a vhost-user-fs-device (virtio-mmio); the guest mounts
    # each tag (fileSystems in the guest config above). The shared guest RAM
    # vhost-user requires comes from the memory-backend-memfd object declared
    # in the guest config (microvm.qemu.extraArgs), because this configuration
    # declares no microvm.shares for microvm.nix to derive one from.
    #
    # Why virtiofs instead of 9p: every omp database under ~/.omp is WAL-mode
    # SQLite, and WAL's wal-index needs a shared mmap of the -shm file. 9p
    # cannot mmap shared files, so omp died at startup with
    # SQLITE_IOERR_SHMMAP (can1357/oh-my-pi#9082). virtiofsd serves mmap and
    # fcntl byte-range locks through to the host kernel — the
    # all-processes-on-one-host access pattern WAL requires. Concurrent VMs
    # stay coherent because their locks serialize in that single kernel.
    qemu_extra=()

    # Start one virtiofsd exporting `dir` at `sock`. "ro" adds --readonly (the
    # host-side equivalent of 9p's readonly=on); rw adds --writeback. The
    # daemon logs into the state dir; its socket appearing is the readiness
    # signal — if it dies instead, surface its log rather than a cryptic QEMU
    # chardev error.
    start_vfsd() {
      local tag="$1" dir="$2" mode="$3" sock="$4"
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
    }

    # The QEMU side of a launcher-owned share. Sockets live in the short
    # per-launch meta_dir: a unix socket path must be shorter than SUN_LEN
    # (108), and the state dir can nest arbitrarily deep. The trap's
    # `rm -rf "$meta_dir"` removes them with the rest.
    add_vfsd() {
      local tag="$1" sock="$2"
      qemu_extra+=(-chardev "socket,id=charvfs_$tag,path=$sock" -device "vhost-user-fs-device,chardev=charvfs_$tag,tag=$tag")
    }

    # The read-only host store is NOT served: the guest has its own store
    # image (microvm.storeOnDisk), so nothing from the host's store — which may
    # hold credentials belonging to other projects — is visible inside the VM.

    start_vfsd project_share "$project_dir" rw "$meta_dir/vfsd-project_share.sock"
    add_vfsd project_share "$meta_dir/vfsd-project_share.sock"

    start_vfsd claude_meta "$meta_dir" ro "$meta_dir/vfsd-claude_meta.sock"
    add_vfsd claude_meta "$meta_dir/vfsd-claude_meta.sock"

    start_vfsd state_dir "$state_dir" rw "$meta_dir/vfsd-state_dir.sock"
    add_vfsd state_dir "$meta_dir/vfsd-state_dir.sock"

    host_claude_dir="''${HOME}/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      start_vfsd claude_auth "$host_claude_dir" rw "$meta_dir/vfsd-claude_auth.sock"
      add_vfsd claude_auth "$meta_dir/vfsd-claude_auth.sock"
    fi

    # omp ("oh my pi"): seed host ~/.omp/agent/config.yml when missing, then
    # share the directory rw (omp rewrites its config at runtime). Unconditional
    # — unlike the -d-guarded claude_auth above — because the seed guarantees
    # the directory exists before the export.
    ${spec.ompConfigSnippet}
    start_vfsd omp_auth "$HOME/.omp" rw "$meta_dir/vfsd-omp_auth.sock"
    add_vfsd omp_auth "$meta_dir/vfsd-omp_auth.sock"

    if [[ -f "$HOME/.gitconfig" ]]; then
      cp "$HOME/.gitconfig" "$meta_dir/gitconfig"
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      start_vfsd git_config_dir "$HOME/.config/git" ro "$meta_dir/vfsd-git_config_dir.sock"
      add_vfsd git_config_dir "$meta_dir/vfsd-git_config_dir.sock"
    fi
    if [[ -d "$HOME/.config/gh" ]]; then
      start_vfsd gh_config_dir "$HOME/.config/gh" ro "$meta_dir/vfsd-gh_config_dir.sock"
      add_vfsd gh_config_dir "$meta_dir/vfsd-gh_config_dir.sock"
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      start_vfsd ssh_dir "$HOME/.ssh" ro "$meta_dir/vfsd-ssh_dir.sock"
      add_vfsd ssh_dir "$meta_dir/vfsd-ssh_dir.sock"
    fi

    # Sandbox LAN NIC (see SANDBOX LAN above): a multicast socket segment with
    # an address allocated per project.
    qemu_extra+=(-netdev "socket,id=lan0,mcast=$lan_group:44881" \
                 -device "virtio-net-device,netdev=lan0,mac=$lan_mac")

    # Guest sizing (see the resolution block near the top): these ride
    # CLAUDE_SANDBOX_VM_QEMU_ARGS into the extraArgsScript hook, whose output
    # lands at the very end of QEMU's argv. Last-wins parsing makes them
    # override the build-time -m/-smp, and the shared memfd backend — which
    # the vhost-user shares require and which sizes the actual guest RAM —
    # carries the memory override. Exactly one id=mem object exists (the
    # build-time one was removed), since QEMU rejects duplicate IDs.
    qemu_extra+=(-m "''${mem_mib}M" -smp "$cpu_count" \
                 -object "memory-backend-memfd,id=mem,size=''${mem_mib}M,share=on" \
                 -numa "node,memdev=mem")

    # microvm.nix starts QEMU with -nographic (no display device at all) and
    # wires the first serial port to stdio; the monitor would still try to mux
    # itself onto that same stdio, so switch it off — the QMP socket above is
    # the control channel.
    qemu_extra+=(-monitor none)

    # The runner word-splits this into QEMU's argv, so every argument must be
    # space-free: the socket paths above are under /tmp or the state dir, and
    # stateDirSnippet mangles whitespace out of the project name.
    export CLAUDE_SANDBOX_VM_QEMU_ARGS="''${qemu_extra[*]} ''${QEMU_OPTS:-}"

    # Volumes and the QMP socket are declared relative to the state dir, which
    # is microvm.nix's convention: the runner is started from its per-VM
    # directory (its host module does the same with /var/lib/microvms/<name>).
    cd "$state_dir"
    # Deliberately NOT `exec`: the runner has to be a child so this shell's EXIT
    # trap survives to kill the virtiofsd daemons. With `exec`, killing QEMU
    # (or the terminal's Ctrl-C) leaves them running — measured: nine daemons per
    # VM leaked per hard kill, holding memory and file handles.
    "${runner}/bin/microvm-run"
  '';
}
# Expose the built guest and the runner so checks can assert on them: the
# mounts only exist in the guest's fstab, and the hypervisor command line only
# in the runner's microvm-run script — neither is visible from a successful
# build.
// {
  vmSystem = microvmSystem.config.system.build.toplevel;
  microvmRunner = runner;
}
