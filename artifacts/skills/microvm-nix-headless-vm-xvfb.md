# Headless microvm.nix VM: no display device, Xvfb inside the guest

## The VM has no display at all

microvm.nix is built for headless VMs. With `microvm.graphics.enable = false`
(its default) the qemu runner passes **`-nographic`** and `-nodefaults`, so the
guest gets *no display device whatsoever* — there is no VGA, nothing to render
into, and nothing to look at from the host. Two things follow:

- **Chromium needs an X server anyway.** Browsers on X11 cannot run without a
  `DISPLAY`; the guest therefore runs its own **Xvfb**, exactly the way this
  project's manager runs Xvfb on the host for the bubblewrap/container backends.
- There is no host window and no way to add one: `-nographic` is what
  microvm.nix emits, and the guest has no display hardware to show.

## What does *not* work

- **`microvm.graphics.enable = true`** adds `-display gtk,gl=on` and a
  `virtio-vga-gl` device. Without a host display GL cannot initialize, and the
  whole point of `graphics` is that GL device — so this is unusable on the
  headless hosts (servers, the manager, plain SSH) that dominate this project's
  use. It is not a fallback that can be toggled at runtime either: the device
  list is baked at evaluation time.
- **`-vga std`** is ignored by microvm.nix's default machine type:
  `warning: A -vga option was passed but this machine type does not use that
  option; No VGA device has been created`. Switching to `q35` would make it
  work again, but there is no reason to want an invisible framebuffer.
- **`-display` cannot be overridden away.** `QEMU_OPTS` is appended last and a
  trailing `-display gtk` *does* win over `-nographic` (measured) — but that is
  the direction we never want, and `-accel`-style overrides are rejected
  outright (`The -accel and "-machine accel=" options are incompatible`).

## What the backend does instead

The guest runs Xvfb as the `sandbox` user:

```nix
systemd.services.claude-xvfb = {
  wantedBy = [ "multi-user.target" ];
  serviceConfig = { User = "sandbox"; Group = "users"; Type = "simple";
                    Restart = "on-failure"; RestartSec = 1;
                    Environment = "HOME=/home/sandbox"; };
  script = "exec ${pkgs.xvfb}/bin/Xvfb :0 -screen 0 1920x1080x24 -nolisten tcp -ac";
};
```

Notes that matter:

- **`-ac`** (disable access control) is what the manager uses on the host, and
  it removes the X-cookie problem completely: the console session rewrites
  `HOME` to the *host* path, so a cookie written next to the guest's real home
  would never be found. This is a single-user sandbox VM; access control buys
  nothing.
- **`DISPLAY=:0` is exported by the console session and nothing orders the
  entrypoint after Xvfb** (it is a plain service, not a display manager), so the
  shell waits briefly for `/tmp/.X11-unix/X0` before starting the agent.
- Chromium then renders with software GL; `hardware.graphics.enable = true` and
  `fonts.enableDefaultPackages = true` replace what `services.xserver` used to
  pull in before Xvfb took its place.
- Screenshots are taken *inside* the guest and read from the shared state
  directory: `DISPLAY=:0 import -window root /mnt/state/shot.png`. There is no
  host-side capture path at all.

## Gotchas

- **Chromium needs a writable `$HOME/.config`.** In this backend `$HOME` is the
  reconstructed host path and `.config` is a symlink to `/home/sandbox/.config`,
  inside which the git/gh share mounts live. systemd creates such mount parents
  as **root**, so the sandbox user cannot create a profile directory: Chromium
  dies with `Failed to create headless user data directory container`, and
  `strace` shows `mkdir("/home/sandbox/.config/chromium-headless") = EACCES`.
  Fix with `systemd.tmpfiles.rules = [ "d /home/sandbox/.config 0700 sandbox
  users -" ]` (tmpfiles runs after local-fs, so it chowns the directory without
  disturbing the mounts inside it). Verified afterwards: `--headless=new
  --dump-dom` exits 0, and on Xvfb `pgrep -c chrome` finds the browser with a
  30 KB screenshot against a 390-byte blank-screen baseline.
- `CHROMIUM_USER_DATA_DIR` does **not** help here: only the wrapper backends
  (bubblewrap/container) read it. Stock Chromium in the VM ignores it, which is
  also why this backend does not persist the browser profile.
- Screenshots must be taken inside the guest (`DISPLAY=:0 import -window root
  /mnt/state/shot.png`) — the host has no path to the guest's display.
- `-nocursor`/`-ac` access control: the guest X server runs with `-ac` because
  the console session rewrites `HOME`, so a cookie would never be found.

## If a visible browser is ever needed again

Either put the VM's X on the network — `x11vnc`/`Xvfb + x11vnc` inside the guest
is the natural move, since nothing outside the guest can see its display — or go
back to `q35` plus an emulated VGA with `Xorg` instead of `Xvfb`, and accept
that the host window then only exists on hosts that have a display.

## References

- `nix/backends/vm.nix` — guest config and launcher
- `artifacts/skills/microvm-nix-cli-vm-integration.md` — the rest of the integration
- `manager/src/display.rs` — the host-side Xvfb precedent (`-ac`, 1920x1080x24)
