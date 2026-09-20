# VM runtime path fixup for session continuity

## Read this first: `fileSystems` is fine with microvm.nix

This backend used to run on nixpkgs' `qemu-vm.nix`, where guest mounts **had**
to be declared as `virtualisation.fileSystems`: `qemu-vm.nix` replaced the whole
`fileSystems` attrset via `mkVMOverride`, so plain `fileSystems` entries were
silently discarded — no error, no warning, nothing in the guest fstab. That is
historical now: the backend builds on microvm.nix, whose guest modules do not
touch `fileSystems`, so the runtime shares are declared there directly (and
`checks.vm-mounts` still asserts every tag reaches the generated fstab).

The rest of this file is unchanged: the problem it solves is that
Claude/omp session state is keyed by the *project's absolute path*, and that
path can only be known at launch.

How to check without booting (works for both backends — inspect the built
system's fstab):

```bash
SYS=$(nix-store -qR result-vm | grep nixos-system | head -1)
grep -N -o '^[a-z_]+ [^ ]* [a-z]*' "$SYS/etc/fstab"
```

If your share is not listed there, it will not mount.

## Problem

Claude Code stores sessions under `~/.claude/projects/<encoded-path>/` where `<encoded-path>` is the project directory's absolute path (slashes → hyphens). When a VM uses fixed mount points (`/project`, `/home/sandbox`), Claude creates sessions under a different key and can't find existing host sessions.

But 9p mount points are **baked at NixOS build time** — you can't use runtime-variable paths in `fileSystems` entries.

## Solution: Meta Dir + Runtime Bind-Mounts

Three-stage approach:

### 1. Launcher writes host paths to meta dir

```bash
echo "$HOME" > "$meta_dir/host_home"
echo "$project_dir" > "$meta_dir/host_project"
```

Meta dir is shared into the VM via a 9p mount at `/mnt/meta`.

### 2. VM reads paths in `interactiveShellInit`

```bash
host_home="$(cat /mnt/meta/host_home)"
host_project="$(cat /mnt/meta/host_project)"
```

### 3. Symlinks for dotfiles, bind-mount for project dir

```bash
# Dotfiles: symlinks work (Claude doesn't realpath() HOME)
mkdir -p "$host_home"
ln -sfn /home/sandbox/.claude "$host_home/.claude"
ln -sfn /home/sandbox/.gitconfig "$host_home/.gitconfig"

# Project dir: MUST use bind-mount, not symlink
sudo mount --bind /project "$host_project"
```

## Why bind-mount, not symlink for project dir?

`getcwd()` (used by shells, `pwd`, and tools like Claude Code) resolves symlinks but NOT bind-mounts. If `/tmp/myproject` is a symlink to `/project`, then `pwd` returns `/project`, breaking the session path encoding. With `mount --bind`, `pwd` returns `/tmp/myproject` as expected.

## Prerequisites

- Passwordless sudo for the sandbox user (the VM is already fully isolated, so this is safe):
  ```nix
  security.sudo = { enable = true; wheelNeedsPassword = false; };
  users.users.sandbox.extraGroups = [ "wheel" ];
  ```

## When This Matters

Any NixOS VM that needs to preserve host paths for tools that encode absolute paths in their state/config. Applies broadly beyond Claude Code.

## References

- `nix/backends/vm.nix` — full implementation
- `artifacts/devlog.md` — "Preserve host paths" entry (2026-02-21)
