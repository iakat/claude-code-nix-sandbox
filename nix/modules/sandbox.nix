# NixOS module for Claude Code sandbox wrappers
#
# Usage in your flake.nix:
#   nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#     modules = [
#       claude-sandbox.nixosModules.default
#       { services.claude-sandbox.enable = true; }
#     ];
#   };
{ config, lib, pkgs, claudeSandbox, ... }:

let
  cfg = config.services.claude-sandbox;

  # Agent harnesses come from this flake's llm-agents.nix input, passed in
  # through `claudeSandbox` (see nixosModules.default in flake.nix) — the
  # host's pkgs needs no overlay to see them.
  agentPkgs = claudeSandbox.agentPackages.${pkgs.stdenv.hostPlatform.system};
  agents = { inherit (agentPkgs) claude-code omp dsh; };

  spec = import ../../nix/sandbox-spec.nix { inherit pkgs agents; };

  chromiumSandbox = pkgs.callPackage ../../nix/chromium.nix {
    chromeExtensionIds = spec.chromeExtensionIds;
  };

  # Guest systems (container, VM) are evaluated here. They need no overlays:
  # spec.packages are pre-evaluated store paths and the guest modules only
  # use stock nixpkgs attrs, so the guest fixpoint is pristine nixpkgs.
  nixos = args: import "${pkgs.path}/nixos/lib/eval-config.nix" {
    modules = [
      { nixpkgs.config.allowUnfree = true; }
    ] ++ args.imports;
    system = pkgs.stdenv.hostPlatform.system;
  };
in
{
  options.services.claude-sandbox = {
    enable = lib.mkEnableOption "Claude Code sandbox wrappers";

    network = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow network access from sandboxes.";
    };

    bubblewrap.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the bubblewrap (bwrap) sandbox.";
    };

    container.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install the systemd-nspawn container sandbox.";
    };

    vm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install the QEMU VM sandbox.";
    };

    bubblewrap.extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages available inside the bubblewrap sandbox.";
    };

    container.extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra NixOS modules for the systemd-nspawn container.";
    };

    container.mem = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        Memory ceiling (systemd MemoryMax) for the container, in MiB.
        null = unlimited. Per-launch override: --mem or CLAUDE_SANDBOX_MEM.
      '';
    };

    container.cpus = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        CPU ceiling (systemd CPUQuota) for the container, in whole CPUs.
        null = unlimited. Per-launch override: --cpus or CLAUDE_SANDBOX_CPUS.
      '';
    };

    vm.extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra NixOS modules for the QEMU VM.";
    };

    vm.mem = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = ''
        Guest RAM for the QEMU VM, in MiB — the default a launch uses.
        Per-launch override: --mem or CLAUDE_SANDBOX_MEM (2048 is rejected:
        it hangs QEMU).
      '';
    };

    vm.vcpu = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = ''
        Guest vCPU count for the QEMU VM — the default a launch uses.
        Per-launch override: --cpus or CLAUDE_SANDBOX_CPUS.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # No host `nixpkgs.config` / overlays needed: the agent harnesses arrive
    # pre-evaluated through `claudeSandbox.agentPackages`, and every backend
    # gets `spec` passed explicitly below.

    environment.systemPackages =
      lib.optional cfg.bubblewrap.enable
        (pkgs.callPackage ../../nix/backends/bubblewrap.nix {
          inherit spec chromiumSandbox;
          inherit (cfg) network;
          inherit (cfg.bubblewrap) extraPackages;
        })
      ++ lib.optional cfg.container.enable
        (pkgs.callPackage ../../nix/backends/container.nix {
          inherit spec chromiumSandbox nixos;
          inherit (cfg) network;
          inherit (cfg.container) mem cpus extraModules;
        })
      ++ lib.optional cfg.vm.enable
        (pkgs.callPackage ../../nix/backends/vm.nix {
          inherit spec nixos;
          microvm = claudeSandbox.microvm;
          inherit (cfg) network;
          inherit (cfg.vm) mem vcpu extraModules;
        });

    # Bubblewrap requires unprivileged user namespaces. The upstream
    # `security.unprivilegedUsernsClone` option was removed from nixpkgs in
    # favour of the sysctl — set it here (overridable by the user).
    boot.kernel.sysctl."user.max_user_namespaces" =
      lib.mkIf cfg.bubblewrap.enable (lib.mkDefault 15000);
  };
}
