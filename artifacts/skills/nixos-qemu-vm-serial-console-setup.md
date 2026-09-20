# NixOS microvm.nix VM serial consoles (claude runs on ttyS0, --enter on ttyS1)

> **Status (2026-09-20):** the VM backend now ships **one console** (ttyS0
> only): one tmux session is enough, `--enter` was removed, and the `microvm`
> machine has one ISA serial anyway. This skill documents the two-console
> pattern — including the `acpi=off` transport-cap interaction that constrains
> it — for when a second console is needed again.

## Two consoles, both serial

| Guest | Host side | Purpose |
|---|---|---|
| `ttyS0` | QEMU stdio (the terminal that ran `claude-sandbox-vm`) | the tmux session with the agent |
| `ttyS1` | a Unix socket in the project state dir | `--enter`: a second login shell in the same VM |

Neither is graphical: the microvm.nix runner is started with `-nographic`, so
there is no VGA and no host window (see
`microvm-nix-headless-vm-xvfb.md`). A VM is not a namespace, so the `nsenter`
trick the bubblewrap/container backends use cannot apply here; a second serial
port is the cheapest way to get a shell into a running VM without sshd, keys or
port forwarding — and it keeps working when the VM has no network.

## Wiring

1. **microvm.nix already puts the first serial port on stdio.**
   `microvm.qemu.serialConsole` defaults to true, which emits
   `-chardev stdio,id=stdio,signal=off -serial chardev:stdio` and adds
   `console=ttyS0` (plus `earlyprintk=ttyS0`) to the kernel command line. No
   `virtualisation.qemu.options`-style plumbing is needed or possible.

2. **The second console is ours.** The launcher appends
   `-serial unix:<state_dir>/console.sock,server,nowait`, which QEMU makes
   `ttyS1` (serials are assigned in command-line order, and ours is appended
   after the runner's). The socket lives in the state dir so `--enter` needs no
   registry: `socat -,raw,echo=0,escape=0x1d unix-connect:<sock>` is the whole
   client, and a missing socket is the liveness check.

3. **`8250.nr_uarts` must be 2.** `microvm.optimize` sets
   `boot.kernelParams = [ "8250.nr_uarts=1" ]` ("we only need one serial
   console"), which means no second UART is probed and `ttyS1` never exists.
   Override with `lib.mkForce` (a plain list would be appended, not replaced):

   ```nix
   boot.kernelParams = lib.mkForce [ "8250.nr_uarts=2" "...other params..." ];
   ```

   `checks.vm-runner` asserts the resulting kernel command line still has it.

4. **Getty + autologin cover both consoles.**
   `services.getty.autologinUser = "sandbox"` is applied through the shared
   `baseArgs` of nixpkgs' getty module, so it reaches `getty@tty1`,
   `serial-getty@ttyS0` **and** any `serial-getty@ttyN` — the second console
   just needs the unit enabled when the hardware is not the console of record:

   ```nix
   systemd.services."serial-getty@ttyS1" = {
     enable = true;
     wantedBy = [ "getty.target" ];
   };
   ```

   (The old advice still holds: do not write a custom `StandardInput=tty`
   service for this — it fights systemd's TTY ownership.)

5. **One shell entrypoint, guarded by `tty`.** `environment.interactiveShellInit`
   does the host-path reconstruction for both consoles but only runs the
   entrypoint on `/dev/ttyS0`; ttyS1 gets an ordinary login shell so you can
   inspect the live VM, `tmux attach`, take screenshots, and so on.

## The primary console runs tmux (omp by default)

`ttyS0`'s entrypoint is not the agent directly but
`tmux -f /mnt/state/tmux.conf new-session -A -s <session>`, so:

- `-A` means the second and later console invocations **attach** to the running
  session; detaching (`Ctrl-a d`, the config sets the prefix to `Ctrl-a`)
  leaves the agent alive.
- The session name is a build-time-agnostic string from the metadata share
  (`omp` by default, `shell` in `--shell` mode), so the entrypoint can be a
  quoted shell command line written to `/mnt/meta/entrypoint` and executed as
  `bash /mnt/meta/entrypoint` — no `eval`-and-word-split dance.
- The tmux config is seeded host-side into the state dir (once, so it stays
  editable) and read through the `/mnt/state` share.

## Gotchas

- **A stale socket blocks bind.** `rm -f` the console and QMP socket paths
  before starting QEMU, or a killed VM's leftovers stop the next launch.
- The QMP socket (`microvm.socket = "qmp.sock"`, relative to the state dir) is
  for control, not for interaction: `screendump` has nothing to capture here
  (no display device), but `system_powerdown` works and microvm.nix's
  `microvm-shutdown` script uses it.
- Because the primary console *is* stdio, anything that scribbles on stdout or
  tries to read stdin inside the guest can disturb the QEMU serial stream; the
  launcher therefore also passes `-monitor none` so the QEMU monitor never
  competes for stdio.

## References

- `nix/backends/vm.nix` — guest console config and launcher
- `artifacts/skills/microvm-nix-cli-vm-integration.md` — build-time vs runtime
  configuration, the store, KVM-less operation
