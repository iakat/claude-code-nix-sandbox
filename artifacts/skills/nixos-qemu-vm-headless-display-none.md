# NixOS QEMU VM headless display fallback

## Problem

A NixOS QEMU VM built via `virtualisation/qemu-vm.nix` with `virtualisation.graphics = true` fails on a headless host (plain SSH, CI, manager-launched tmux) with:

```
gtk initialization failed
```

right after disk creation. The VM never boots.

## Why it happens

With `graphics = true`, qemu-vm.nix adds **no `-display` flag at all** — `-nographic` is only added when `graphics = false`. QEMU then falls back to its compiled-in default UI, which is **GTK** in the nixpkgs qemu build. GTK cannot initialize without a display, so QEMU exits before the guest starts.

## Solution: append `-display none` via `QEMU_OPTS`

`$QEMU_OPTS` is the injection point for a wrapper around the generated `run-*-vm` script: qemu-vm.nix places it **unquoted and second-to-last** on QEMU's command line (only `"$@"` after), so flags appended there always reach QEMU and cannot be shadowed.

```bash
qemu_extra+=(-display none)
export QEMU_OPTS="${qemu_extra[*]} ${QEMU_OPTS:-}"
```

`-display none` drops only the host-side window. The emulated VGA device still exists, so the guest's Xorg and Chromium keep rendering normally, and an explicit `-serial stdio` console is unaffected. It is the correct headless mode for a VM whose GUI runs *inside* the guest.

### Detecting headless

Don't trust the environment — probe it:

- `DISPLAY` set: probe with `xset -q` (one X round trip; `xdpyinfo` does dozens and is slow over SSH -X). `DISPLAY` can be set but dead — stale SSH -X forwarding, or a tmux pane whose server inherited a desktop environment that has since gone away.
- `WAYLAND_DISPLAY` set (with `XDG_RUNTIME_DIR`): check the compositor socket exists; there is no cheap Wayland client to probe with.
- Neither: definitely headless.

Run probes only in `if`-condition position (`if ! xset -q ...`) — writeShellApplication enables `errexit`, and a failing probe in a plain command position would abort the script.

## Gotchas

- **`-display none` must reach QEMU as two argv entries.** The generated script word-splits the unquoted `$QEMU_OPTS`, so append `-display` and `none` as separate bash array elements (`qemu_extra+=(-display none)`), never one string.
- **Not `-nographic`**: it multiplexes the monitor onto serial and changes console semantics, colliding with an explicit `-serial stdio`.
- **Not `virtualisation.graphics = false`**: that adds `-nographic` (same problem), flips the preferred console, and tightens kernel-config assertions (`SERIAL_8250_CONSOLE` must be built in).
- **QEMU keeps a single display config: the LAST `-display` silently wins** (only `-vnc` accumulates separately). Appending a user-provided `QEMU_OPTS` *after* ours therefore makes our `-display none` an overridable default — `QEMU_OPTS='-display gtk'` restores the window, `QEMU_OPTS='-vnc :0'` adds a VNC viewer alongside the disabled frontend (useful on headless servers).
- **Manager/daemon context counts as headless even on a desktop host**: a daemon spawning the wrapper in tmux typically has no `DISPLAY` (or a leaked dead one), so the probe-based detection fires — which is what you want, since QEMU's GTK would fail there anyway.
