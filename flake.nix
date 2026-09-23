{
  description = "Sandboxed Claude Code sessions with Chromium via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    claude-code-nix.inputs.nixpkgs.follows = "nixpkgs";
    omp.url = "github:can1357/oh-my-pi";
    omp.inputs.nixpkgs.follows = "nixpkgs";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, claude-code-nix, omp, microvm }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      sandboxOverlay = final: prev: {
        sandboxSpec = import ./nix/sandbox-spec.nix { pkgs = final; };
        chromiumSandbox = prev.callPackage ./nix/chromium.nix {
          chromeExtensionIds = final.sandboxSpec.chromeExtensionIds;
        };
      };
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ];
      };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.symlinkJoin {
            name = "claude-code-sandbox";
            paths = [
              (pkgs.callPackage ./nix/backends/bubblewrap.nix { })
              pkgs.claude-code
            ];
          };

          # Bubblewrap sandbox only (without bundled claude-code)
          sandbox = pkgs.callPackage ./nix/backends/bubblewrap.nix { };
          # Bubblewrap sandbox with /dev/kvm passed through: run the VM backend
          # (nested virt) from inside a sandbox instead of falling back to TCG
          sandbox-kvm = pkgs.callPackage ./nix/backends/bubblewrap.nix { kvm = true; };

          # Variant with network isolation
          no-network = pkgs.callPackage ./nix/backends/bubblewrap.nix {
            network = false;
          };

          # systemd-nspawn container backend (requires sudo)
          container = pkgs.callPackage ./nix/backends/container.nix {
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [ { nixpkgs.overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ]; } ] ++ args.imports;
            });
          };

          container-no-network = pkgs.callPackage ./nix/backends/container.nix {
            network = false;
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [ { nixpkgs.overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ]; } ] ++ args.imports;
            });
          };

          # microvm.nix VM backend (strongest isolation)
          vm = pkgs.callPackage ./nix/backends/vm.nix {
            inherit microvm;
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [ { nixpkgs.overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ]; } ] ++ args.imports;
            });
          };

          vm-no-network = pkgs.callPackage ./nix/backends/vm.nix {
            inherit microvm;
            network = false;
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [ { nixpkgs.overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ]; } ] ++ args.imports;
            });
          };

          # Remote sandbox manager (Rust/Axum web dashboard)
          manager = pkgs.callPackage ./nix/manager/package.nix {
            sandboxPackages = [
              (pkgs.callPackage ./nix/backends/bubblewrap.nix { })
            ];
          };

          # Local CLI for managing remote sandboxes via SSH
          cli = pkgs.callPackage ./scripts/claude-remote.nix { };

          # Documentation site (mdBook)
          # nix build .#docs  → static HTML in result/
          # nix run  .#docs   → live preview via mdbook serve
          docs = let
            docsSrc = ./docs;
            serveScript = pkgs.writeShellScript "claude-sandbox-docs" ''
              dest=$(mktemp -d)
              trap 'rm -rf "$dest"' EXIT
              exec ${pkgs.mdbook}/bin/mdbook serve ${docsSrc} --dest-dir "$dest"
            '';
          in pkgs.stdenv.mkDerivation {
            name = "claude-sandbox-docs";
            src = docsSrc;
            nativeBuildInputs = [ pkgs.mdbook ];
            buildPhase = "mdbook build";
            installPhase = ''
              mkdir -p $out/bin
              cp -r book/* $out/
              ln -s ${serveScript} $out/bin/claude-sandbox-docs
            '';
          };
        });

      # NixOS modules
      #
      # The sandbox module evaluates the container/VM guest systems itself, so
      # it needs what only this flake has: the microvm.nix input, and the
      # overlays that provide claude-code/omp (the host's pkgs cannot supply
      # them). Both arrive as module arguments.
      nixosModules.default = { ... }: {
        imports = [ ./nix/modules/sandbox.nix ];
        _module.args.claudeSandbox = {
          inherit microvm;
          overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ];
        };
      };
      nixosModules.manager = ./nix/modules/manager.nix;

      # Checks: build all packages + NixOS VM tests
      checks = forAllSystems (system:
        let pkgs = pkgsFor system;
        in
        self.packages.${system} // {
          manager-test = pkgs.testers.nixosTest (import ./tests/manager.nix { inherit self; });

          # Assert the guest mounts every share, plus the store layer that
          # keeps the base image shared and the per-project delta on a volume.
          #
          # Building .#vm cannot catch a dropped mount: a wrong attribute in the
          # guest config is silently ignored, and the VM then boots with no
          # project dir, no ~/.claude and no /mnt/meta (which carries the
          # entrypoint). Only the generated fstab shows it. The check exists
          # because exactly that happened under the old qemu-vm.nix backend,
          # whose mkVMOverride discarded plain `fileSystems` entries without a
          # word.
          vm-mounts = pkgs.runCommand "vm-mounts-check" { } ''
            fstab=${self.packages.${system}.vm.vmSystem}/etc/fstab
            missing=""
            # One virtiofs mount per share the launcher serves (the guest's own
            # store disk is not a share), named by their tag.
            for tag in project_share claude_auth omp_auth \
                       git_config_dir gh_config_dir ssh_dir claude_meta state_dir; do
              grep -qE "^$tag [^ ]+ virtiofs( |$)" "$fstab" || missing="$missing $tag"
            done
            if [ -n "$missing" ]; then
              echo "virtiofs shares missing from the guest fstab:$missing" >&2
              echo "Declare them in the guest module as fileSystems with fsType = \"virtiofs\"." >&2
              echo "--- generated fstab ---" >&2
              cat "$fstab" >&2
              exit 1
            fi
            # The store must be the guest's own immutable image (never the host
            # store), with the writable layer provided by the overlay unit.
            grep -qE "^/dev/disk/by-label/nix-store /nix/store erofs " "$fstab" || {
              echo "the read-only store is not the guest's own erofs image:" >&2
              cat "$fstab" >&2
              exit 1
            }
            test -e ${self.packages.${system}.vm.vmSystem}/etc/systemd/system/nix-store-overlay.service || {
              echo "nix-store-overlay.service is missing: nothing would make the store writable" >&2
              exit 1
            }
            for mount in /nix/.rw-store /var/lib/docker; do
              grep -qE "^[^ ]+ $mount ext4 " "$fstab" || {
                echo "$mount is not backed by a volume in the guest fstab:" >&2
                cat "$fstab" >&2
                exit 1
              }
            done
            touch $out
          '';

          # Assert the hypervisor flags this backend depends on. They are
          # generated by microvm.nix and surface nowhere else — only the
          # runner's microvm-run script carries the command line, so a dropped
          # or renamed option would change guest behaviour with no build error:
          #   microvm          the machine type proper: no display device, no
          #                    PCI — every device rides virtio-mmio
          #   mem-merge=on     QEMU marks guest RAM MADV_MERGEABLE for KSM
          #                    (only effective for private RAM; see the note in
          #                    the guest config)
          #   vhost-user-fs-device  the runtime shares attach over virtio-mmio
          #   free-page-reporting=on  the balloon reports freed pages so the
          #                    host can reclaim them
          #   -nographic       headless: no display device and no host window
          # The machine options are otherwise microvm.nix's upstream defaults
          # (pit=off et al) — this backend requires KVM, see the guest comment.
          vm-runner = pkgs.runCommand "vm-runner-check" { } ''
            run=${self.packages.${system}.vm.microvmRunner}/bin/microvm-run
            launcher=${self.packages.${system}.vm}/bin/claude-sandbox-vm
            # build-time command line (the runner script). The shared memfd is
            # deliberately ABSENT here: it is emitted by the launcher at
            # launch time so guest RAM/CPU can be overridden per launch (a
            # second id=mem object would make QEMU abort).
            for probe in "microvm," "acpi=on" "mem-merge=on" \
                         "free-page-reporting=on" "virtio-net-device" "-nographic"; do
              grep -qF -- "$probe" "$run" || {
                echo "the generated hypervisor command line is missing: $probe" >&2
                exit 1
              };
            done
            ! grep -qF "memory-backend-memfd" "$run" || {
              echo "the runner still emits the shared memfd; the launcher must own it (duplicate id=mem aborts QEMU)" >&2
              exit 1
            }
            # launch-time command line: the launcher injects these via
            # CLAUDE_SANDBOX_VM_QEMU_ARGS (word-split by the extraArgsScript
            # hook, landing LAST in QEMU's argv — last-wins parsing overrides
            # the build-time -m/-smp). The memfd/numa pair sizes the actual
            # guest RAM for the vhost-user shares; --mem/--cpus + env pick the
            # values per launch.
            for probe in "vhost-user-fs-device" "virtio-net-device" \
                         "memory-backend-memfd" "node,memdev=mem" "-smp" "--mem" "--cpus"; do
              grep -qF -- "$probe" "$launcher" || {
                echo "the launcher's hypervisor arguments are missing: $probe" >&2
                exit 1
              };
            done
            touch $out
          '';
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = [
              (pkgs.callPackage ./scripts/claude-remote.nix { })
            ] ++ (with pkgs; [
              nixd           # Nix LSP
              nil            # Alternative Nix LSP
              nixpkgs-fmt    # Nix formatter
            ]);
          };

          # Rust dev shell for the manager
          manager = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              rust-analyzer
              pkg-config
              openssl
            ];
          };
        });
    };
}
