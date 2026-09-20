{
  description = "Sandboxed Claude Code sessions with Chromium via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    claude-code-nix.inputs.nixpkgs.follows = "nixpkgs";
    omp.url = "github:can1357/oh-my-pi";
    omp.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, claude-code-nix, omp }:
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

          # QEMU VM backend (strongest isolation)
          vm = pkgs.callPackage ./nix/backends/vm.nix {
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [ { nixpkgs.overlays = [ claude-code-nix.overlays.default omp.overlays.default sandboxOverlay ]; } ] ++ args.imports;
            });
          };

          vm-no-network = pkgs.callPackage ./nix/backends/vm.nix {
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
      nixosModules.default = ./nix/modules/sandbox.nix;
      nixosModules.manager = ./nix/modules/manager.nix;

      # Checks: build all packages + NixOS VM tests
      checks = forAllSystems (system:
        let pkgs = pkgsFor system;
        in
        self.packages.${system} // {
          manager-test = pkgs.testers.nixosTest (import ./tests/manager.nix { inherit self; });

          # Assert every 9p share reaches the guest fstab.
          #
          # Building .#vm cannot catch this. qemu-vm.nix replaces the whole
          # fileSystems attrset via mkVMOverride, so a share declared with
          # `fileSystems` instead of `virtualisation.fileSystems` is silently
          # dropped: no eval error, no warning, a VM that builds perfectly and
          # mounts nothing. That is exactly what happened — the guest had no
          # project dir, no ~/.claude and no /mnt/meta (which carries the
          # entrypoint) — and every build-based check passed throughout.
          vm-mounts = pkgs.runCommand "vm-mounts-check" { } ''
            fstab=${self.packages.${system}.vm.vmSystem}/etc/fstab
            missing=""
            for tag in project_share claude_auth omp_auth git_config_dir \
                       gh_config_dir ssh_dir claude_meta state_dir; do
              grep -qE "^$tag " "$fstab" || missing="$missing $tag"
            done
            if [ -n "$missing" ]; then
              echo "9p shares missing from the guest fstab:$missing" >&2
              echo "Declare them as virtualisation.fileSystems, not fileSystems." >&2
              echo "--- generated fstab ---" >&2
              cat "$fstab" >&2
              exit 1
            fi
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
