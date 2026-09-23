# Customization

All backends are `callPackage`-able Nix functions, so you can override their parameters directly in your flake.

## Resource limits (RAM & CPUs)

The container and VM backends take `mem` (MiB) and `cpus` parameters as
launch-time defaults, overridable per launch with `--mem`/`--cpus` or
`CLAUDE_SANDBOX_MEM`/`CLAUDE_SANDBOX_CPUS` — no rebuild needed:

```bash
claude-sandbox-vm --mem 8192 --cpus 8 ~/project
sudo claude-sandbox-container --mem 8192 --cpus 4 ~/project
```

In the NixOS module these are `services.claude-sandbox.vm.mem` /
`vm.vcpu` (allocations, applied to the QEMU command line at launch) and
`services.claude-sandbox.container.mem` / `container.cpus` (ceilings, applied
as systemd `MemoryMax`/`CPUQuota` on the container's scope unit). The
bubblewrap backend cannot enforce resource limits: it is unprivileged and has
no cgroup authority — use the container or VM backend when limits matter.

## Extra packages (bubblewrap)

Add packages to the sandbox PATH via `extraPackages`:

```nix
packages.default = pkgs.callPackage ./nix/backends/bubblewrap.nix {
  extraPackages = with pkgs; [ python3 nodejs ripgrep ];
};
```

## Extra NixOS modules (container / VM)

Add NixOS configuration to the container or VM via `extraModules`:

```nix
packages.container = pkgs.callPackage ./nix/backends/container.nix {
  nixos = args: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = args.imports;
  };
  extraModules = [{
    environment.systemPackages = with pkgs; [ python3 nodejs ];
    # Any NixOS option works here
  }];
};
```

For the VM backend, you can also configure VM-specific options:

```nix
packages.vm = pkgs.callPackage ./nix/backends/vm.nix {
  nixos = args: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = args.imports;
  };
  extraModules = [{
    virtualisation.memorySize = 8192;
    virtualisation.cores = 8;
    environment.systemPackages = with pkgs; [ python3 ];
  }];
};
```

## Network isolation

All backends accept `network = false` to disable network access:

```nix
# Bubblewrap: adds --unshare-net
packages.isolated = pkgs.callPackage ./nix/backends/bubblewrap.nix {
  network = false;
};

# Container: adds --private-network
packages.container-isolated = pkgs.callPackage ./nix/backends/container.nix {
  nixos = args: nixpkgs.lib.nixosSystem { ... };
  network = false;
};

# VM: disables DHCP, empties vlans
packages.vm-isolated = pkgs.callPackage ./nix/backends/vm.nix {
  nixos = args: nixpkgs.lib.nixosSystem { ... };
  network = false;
};
```

Pre-built network-isolated variants are available as `no-network`, `container-no-network`, and `vm-no-network` packages.

## Manager sandbox backends

Configure which backends the manager can use via `sandboxPackages`:

```nix
packages.manager = pkgs.callPackage ./nix/manager/package.nix {
  sandboxPackages = [
    (pkgs.callPackage ./nix/backends/bubblewrap.nix { })
    (pkgs.callPackage ./nix/backends/bubblewrap.nix { network = false; })
  ];
};
```

## Using as a flake input

```nix
{
  inputs.claude-sandbox.url = "github:jhhuh/claude-code-nix-sandbox";
  inputs.claude-code-nix.url = "github:sadjow/claude-code-nix";

  outputs = { nixpkgs, claude-sandbox, claude-code-nix, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ claude-code-nix.overlays.default ];
      };
    in {
      # Use a backend directly (needs claude-code-nix overlay for pkgs.claude-code)
      packages.x86_64-linux.my-sandbox = pkgs.callPackage
        "${claude-sandbox}/nix/backends/bubblewrap.nix"
        { extraPackages = [ pkgs.python3 ]; };

      # Or use the pre-built packages (overlay already applied)
      packages.x86_64-linux.sandbox = claude-sandbox.packages.x86_64-linux.default;
    };
}
```
