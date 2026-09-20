# Dev Journal — claude-code-nix-sandbox

## 2026-02-17 — Initial scaffolding + bubblewrap backend

Scaffolded flake.nix, directory structure, CLAUDE.md. Built the bubblewrap sandbox backend (`nix/backends/bubblewrap.nix`) as a `writeShellApplication` wrapping `bwrap`.

Key decisions:
- `symlinkJoin` to build a unified PATH from packages (claude-code, chromium, coreutils, bash, git)
- Dynamic bash arrays for optional flags (display, D-Bus, GPU, auth, network) — cleaner than inline conditionals
- `--die-with-parent` so sandbox dies if launcher exits
- Project dir bound read-write at its real path, everything else isolated

Iterated on D-Bus forwarding (Chromium needs session bus), GPU/DRI forwarding (`/dev/dri` + `/run/opengl-driver` on NixOS), and Xauthority handling.

Added `--shell` mode and `~/.claude` bind-mount for auth persistence across sessions.

## 2026-02-17 — systemd-nspawn container backend

Built `nix/backends/container.nix` using `nixosSystem` to evaluate a NixOS config and get a system closure (`toplevel`). Creates an ephemeral container root at runtime with `/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf` stubs.

**Problem**: `runuser`/`su` fail inside the container because PAM is not available (no `/etc/pam.d`).
**Fix**: Replaced with `setpriv --reuid=1000 --regid=1000 --init-groups` which drops privileges without PAM. See skill file: `nspawn-privilege-drop-without-pam.md`.

**Problem**: `--console=pipe` was always set for non-shell mode, breaking interactive TTY sessions.
**Fix**: Only use `--console=pipe` when `! -t 0` (stdin is not a terminal).

Added D-Bus session bus address env var, host config forwarding (DNS, TLS, fonts, timezone).

## 2026-02-17 — QEMU VM backend

Built `nix/backends/vm.nix` — full NixOS VM with QEMU, 4GB RAM, 4 cores.

Design: claude-code runs on serial console (user's terminal), Chromium renders in QEMU GTK window via Xorg+openbox. Project dir shared via 9p virtfs.

**Problem**: No serial output from VM — QEMU wasn't started with `-serial` flag.
**Fix**: Added `-serial stdio` to `virtualisation.qemu.options`.

**Problem**: Serial console wasn't primary — Linux `console=` had `tty0` last.
**Fix**: Reversed order via `virtualisation.qemu.consoles = [ "tty0" "ttyS0,115200n8" ]`. See skill file: `nixos-qemu-vm-serial-console-setup.md`.

**Problem**: Custom systemd service on ttyS0 had TTY management issues (TTYReset, ordering).
**Fix**: Replaced with NixOS built-in `services.getty.autologinUser` + `environment.interactiveShellInit` that checks `$(tty) == /dev/ttyS0`.

Tested: Chromium headless DOM dump works, uid=1000, version confirmed.

## 2026-02-17 — NixOS module + flake checks

Added `nix/modules/sandbox.nix` — declarative NixOS module with `services.claude-sandbox` options (enable, network, bubblewrap/container/vm toggles). Sets `security.unprivilegedUsernsClone = true` for bubblewrap.

Added `checks` output to flake.nix referencing all packages for CI validation.

## 2026-02-17 — Nix-daemon forwarding in sandboxes

User asked: "Shouldn't we bind mount host nix-daemon socket so that we can build something inside vm/container?"

Added `/nix/var/nix/daemon-socket` bind-mount to bubblewrap and container backends.

**Problem**: Read-only bind of unix socket fails (Permission denied).
**Fix**: Changed to read-write bind for the daemon socket.

**Problem**: `nix eval` tried to access `/nix/var/nix/db/big-lock` directly instead of going through daemon.
**Fix**: Set `NIX_REMOTE=daemon` env var to force daemon mode. Also added `nix` package to sandbox PATH. See skill file: `nix-daemon-socket-forwarding-in-sandboxes.md`.

Verified: `nix eval nixpkgs#hello.name` returns `"hello-2.12.1"` inside bubblewrap sandbox.

## 2026-02-17 — Bug fixes and feature audit

Ran a systematic comparison of all three backends. Found and fixed:

**Bugs fixed:**
- Container nix daemon socket was bound read-only (`--bind-ro`), preventing `nix` from connecting. Changed to `--bind`.
- Bubblewrap unconditionally set empty env vars (DISPLAY, WAYLAND_DISPLAY, XAUTHORITY, DBUS_SESSION_BUS_ADDRESS, ANTHROPIC_API_KEY). Made conditional — only set when non-empty on host.
- Container and VM entrypoint quoting: `exec $ENTRYPOINT` word-split on spaces. Fixed with `printf '%q'` + `eval exec`.
- VM hardcoded disk image path `/tmp/claude-sandbox-vm.qcow2` caused collisions between concurrent runs. Now uses `mktemp` + `NIX_DISK_IMAGE` env var.
- Container pre-created `.claude` dir even when host dir was absent. Removed from unconditional `mkdir`.

**Consistency fixes:**
- Added `nix` package to VM's `environment.systemPackages` (was missing, unlike bwrap/container).

**New features:**
- PipeWire and PulseAudio audio forwarding for bubblewrap and container. Forwards `pipewire-0` and `pulse/native` sockets.
- Git config (`~/.gitconfig`) and SSH key (`~/.ssh`) forwarding (read-only) to all three backends. SSH agent socket forwarded via `SSH_AUTH_SOCK`.
- GitHub Actions CI: `.github/workflows/ci.yml` runs `nix flake check` on push/PR.

**Further hardening:**
- Container machine name now uses unique suffix from mktemp to prevent collisions between concurrent nspawn instances.
- Container nix db/daemon-socket binds made conditional (was hard-failing on systems without these paths).
- Locale forwarding added: LANG, LC_ALL env vars and `/etc/locale.conf` for both bubblewrap and container.
- home-manager git config support: forward `~/.config/git/` in addition to `~/.gitconfig` (all three backends).
- Forward `/etc/nsswitch.conf` into bubblewrap for proper NSS-based lookups.

Verified: git config, SSH keys, locale, nix all work correctly inside bubblewrap sandbox.

## 2026-02-17 — UID mapping and remaining consistency

**Container UID mapping**: Replaced all hardcoded uid 1000 references with dynamic detection via `id -u "${SUDO_USER:-${USER}}"`. The container now creates the sandbox user with the real invoking user's UID/GID, preventing file ownership mismatches when the host user is not uid 1000. Affected: `/etc/passwd`, `/etc/group`, `setpriv` args, `chown`, and all `/run/user/` paths.

**Container config alignment**: Forwarded `/etc/nix`, `/etc/static`, `/etc/nsswitch.conf` into container to match bubblewrap's host config forwarding.

ShellCheck caught unquoted `$real_uid` inside array assignments — all instances quoted to pass `writeShellApplication` validation.

## 2026-02-17 — Polish and completeness

**openssh**: Added `openssh` to all three backends' package lists. Git SSH transport (`git push/pull` over SSH) was silently failing because `ssh` wasn't on PATH inside the sandbox.

**CI improvement**: Split GitHub Actions into two jobs — `build` (matrix: default, no-network) actually builds the bubblewrap variants; `eval` evaluates all packages and the NixOS module without full build. Container/VM packages build entire NixOS systems and are too expensive for CI free tier.

**CLI UX**: Added `--help`/`-h` flag to all three backends with consistent usage messages.

**NixOS module**: Added `bubblewrap.extraPackages`, `container.extraModules`, and `vm.extraModules` options to match the customization interface available via direct `callPackage`. README updated with commented examples.

**Documentation**: README updated with git/SSH/nix/locale forwarding details, `extraPackages`/`extraModules` customization section, NixOS module examples.

## 2026-02-17 — Add project sync to claude-remote CLI

Added `sync` and `watch` commands to `claude-remote` for syncing project directories to/from the remote server. Also added `--sync` flag to `create` for one-shot sync before sandbox creation.

- `sync <dir> [remote]`: one-shot rsync local→remote, excludes `.git/`, respects `.gitignore`
- `watch <dir> [remote]`: continuous bidirectional sync — fswatch for local→remote (with event debouncing), background rsync loop every 2s for remote→local (picks up Claude's modifications)
- `create --sync`: runs one-shot sync before calling the create API
- Added `rsync` and `fswatch` to `runtimeInputs` in `scripts/claude-remote.nix`

## 2026-02-17 — NixOS VM integration test for remote manager

Added `tests/manager.nix` — a `nixosTest` that exercises the full manager API lifecycle in a QEMU VM. Uses a stub `claude-sandbox` (`sleep 300`) to avoid needing the real backend.

Test covers: service startup, empty list, system metrics, create sandbox, list with one entry, stop, verify stopped, delete, verify empty, state.json validity. All 9 steps pass in ~13s.

Key details:
- `pkgs.testers.nixosTest` (not `pkgs.nixosTest` — removed from nixpkgs)
- Stub added via `sandboxPackages` module option (goes to systemd `path`)
- Set `SHELL=${pkgs.bash}/bin/bash` in service environment — system user defaults to nologin, which breaks tmux session creation
- Wired into flake `checks` as `manager-test`, runnable via `nix build .#checks.x86_64-linux.manager-test -L`
- Noted deprecation warning: `xorg.xorgserver` → `xorg-server` (in `package.nix`, not fixed here)

## 2026-02-17 — Documentation site with mdBook + GitHub Pages

Added a full documentation site using mdBook:

- `docs/` directory with `book.toml`, `SUMMARY.md`, and 14 content pages covering all backends, remote manager (CLI, API, dashboard), NixOS modules, customization, and architecture
- `packages.docs` in flake.nix — `stdenv.mkDerivation` with `mdbook build`
- `.github/workflows/docs.yml` — builds via Nix, deploys to GitHub Pages using `actions/deploy-pages`
- Content derived from README + source code reading (backends, modules, manager Rust source, CLI)
- Verified: `nix build .#docs` succeeds, `nix flake check` passes (docs included in checks)

## 2026-02-18 — Config file support for claude-remote CLI

Added config file loading to `claude-remote` so users don't need to export env vars in every shell session.

- Config location: `${XDG_CONFIG_HOME:-~/.config}/claude-remote/config`
- Format: simple `key = value` lines, comments with `#`, blank lines ignored
- Supported keys: `host`, `port`, `ssh_opts`
- Precedence: env var > config file > default
- Pure bash parsing (no extra deps) — `while read` loop with `%%`/`#` parameter expansion for key/value splitting
- Updated help text to show config file location and example
- Updated mdBook docs (`docs/src/remote-manager/cli.md`) with config file section
- Nix escaping gotcha: `${...}` in comments inside `''` strings is still interpolated by Nix — must use `''${` escape even in bash comments

## 2026-02-18 — Switch claude-code to sadjow/claude-code-nix

Replaced nixpkgs' `claude-code` with the package from `github:sadjow/claude-code-nix`.

- Added `claude-code-nix` flake input with `inputs.nixpkgs.follows = "nixpkgs"` to share the same nixpkgs
- Applied `claude-code-nix.overlays.default` to `pkgsFor` so `pkgs.claude-code` resolves from the flake for bubblewrap backend (via `callPackage`)
- Also injected the overlay into every `nixosSystem` call (container and VM backends) via `nixpkgs.overlays` module — without this, those NixOS evaluations would still pull `claude-code` from upstream nixpkgs
- Backend `.nix` files unchanged — they still reference `pkgs.claude-code`, which the overlay shadows
- Updated CLAUDE.md conventions section
- Updated docs: introduction mentions sadjow/claude-code-nix, customization flake input example shows the overlay, NixOS module docs softened `allowUnfree` note

## 2026-02-21 — Preserve host paths inside sandbox backends

Claude Code stores sessions in `~/.claude/projects/<encoded-path>/` where `<encoded-path>` is the project directory's absolute path with `/` replaced by `-`. When the sandbox uses synthetic paths (`/home/sandbox`, `/project`), Claude creates sessions under a different key and can't find existing host sessions.

**Bubblewrap**: Changed `sandbox_home="/home/sandbox"` → `sandbox_home="$HOME"`. Everything else cascades through the variable — bind mounts, `--setenv HOME`, `--dir`, etc.

**Container**: Moved `real_home`/`real_user` definitions up before `mkdir`. Replaced all `/home/sandbox` references with `$real_home` (passwd entry, Xauthority, .claude, .gitconfig, .config/git, .ssh bind targets). Replaced `/project` with `$project_dir` (bind mount, chown, cd, entrypoint).

**VM**: 9p mount points are baked at NixOS build time, so runtime fixups are needed. Launcher writes `$HOME` and `$project_dir` to meta dir. Added passwordless sudo (`wheel` group) for the sandbox user (VM is already fully isolated). `interactiveShellInit` reads host paths from `/mnt/meta/`, creates real home dir, symlinks dotfiles from `/home/sandbox/` to `$host_home/`, and bind-mounts `/project` to `$host_project`. Bind mount (not symlink) for project dir because `getcwd()` resolves symlinks but not bind mounts.

## 2026-02-24 — Knowledge catch-up: skill extraction and session tooling

Reviewed all git history and Claude Code session files to identify undocumented patterns. The devlog was already current with all commits — no missing entries.

**Session summarizer tool**: Built `artifacts/tools/session-summarizer.sh` — a jq/bash script that extracts human-readable conversation from Claude Code JSONL session files without loading multi-MB tool results into context. Modes: `--overview` (compact conversation), `--user-only` (just human messages), `--tools` (tool use frequency), `--commits` (git commits made). Key insight: session JSONL has `user`/`assistant`/`system`/`progress`/`queue-operation`/`file-history-snapshot` types; only `user` and `assistant` carry useful content, and assistant `tool_use` blocks are the bulk of file size.

**New skill files extracted** (7 total, from code patterns and session history):
- `nix-writeShellApplication-escaping-and-shellcheck.md` — the `''${` escape for bash vars in Nix strings, SC2155 (declare/assign separately), SC2029 (SSH vars)
- `vm-9p-runtime-path-fixup-for-session-continuity.md` — meta dir + bind-mount pattern for preserving host paths when 9p mounts are baked at build time
- `nix-overlay-injection-into-nixosSystem-calls.md` — overlays applied to `pkgsFor` don't propagate to `nixosSystem` calls; must inject via `nixpkgs.overlays` module
- `nixos-vm-integration-test-with-stub-services.md` — `pkgs.testers.nixosTest` (not `pkgs.nixosTest`), stub backends, system user shell gotcha
- `ssh-remote-cli-printf-q-escaping.md` — `printf '%q'` for SSH argument escaping
- `bubblewrap-dynamic-bash-arrays-for-optional-flags.md` — bash arrays for conditional bwrap flags (empty arrays expand to nothing)
- `claude-code-session-jsonl-extraction.md` — JSONL structure, jq extraction patterns, the summarizer tool

Updated CLAUDE.md skill files section with all new entries.

## 2026-02-27 — Sandbox hardening: auth, Chrome isolation, cleanup

Multiple fixes to sandbox backends for real-world multi-instance usage.

**Container ~/.claude not mounting**: `real_home` used `SUDO_HOME` which isn't a real env var. Under sudo with `env_reset`, `HOME=/root`, so the bind check for `/root/.claude` silently failed. Fixed by resolving home from `getent passwd` (consistent with how `real_uid`/`real_gid` already use `id(1)`).

**~/.claude.json forwarding**: Added to all three backends. Bubblewrap and container bind-mount it read-write; VM copies it into the meta dir.

**Security guide acceptance**: `~/.claude` is now always created on the host (`mkdir -p`) before bind-mounting, so first-run security acceptance persists. Previously the conditional `if [[ -d ]]` check meant first-run writes went to tmpfs and were lost.

**Chrome session stealing between sandboxes**: Three root causes identified and fixed:
1. Shared D-Bus session bus — Chromium registers `org.chromium.Chromium` on D-Bus, letting the second sandbox's Chrome discover the first. Removed session bus forwarding from both backends (system bus kept for NetworkManager etc.)
2. Abstract socket collision — Chromium derives abstract Unix socket names from the profile path string. Mounting different storage to the same in-sandbox path (`~/.config/chromium`) produces identical socket names on the shared network namespace. Fixed by creating a wrapper script at `<project-dir>/.config/chromium-wrapper/chromium` that calls the real binary with `--user-data-dir=<project-dir>/.config/chromium` (unique real path per project). Wrapper prepended to PATH.
3. Wrapper shebang: must use `#!/usr/bin/env sh` (not `#!/bin/sh`) because bubblewrap sandboxes don't have `/bin/sh`.

Verified: two concurrent bubblewrap sandboxes with chromium — each got independent CDP ports (41899, 35605), independent SingletonLock files, no session stealing.

**`/usr/bin/env`**: Added to bubblewrap (`--dir /usr/bin --ro-bind-try`) and container (`ln -s ${toplevel}/sw/bin/env`). Scripts with `#!/usr/bin/env` shebangs now work.

**GitHub CLI forwarding**: `~/.config/gh` always bind-mounted read-only (like gitconfig). New `--gh-token` flag opts into forwarding `GH_TOKEN`/`GITHUB_TOKEN` env vars. Flag parsing upgraded to `while` loop supporting multiple `--` options in both backends.

**Stale temp dir cleanup**: Container and VM backends now sweep orphaned `/tmp/claude-nspawn.*` and `/tmp/claude-vm-meta.*` dirs on startup. Container checks `machinectl show` to skip running instances; VM uses `fuser` to skip in-use disk images.


## 2026-07-07 — Fix login prompt on every sandbox creation (~/.claude.json copy seeding)

Commits `a4764aa`/`3b285ad` stopped sharing `~/.claude.json` (bind-mounting the
live file raced with host claude-code's atomic-rename rewrites and aborted
launches). Side effect discovered in use: `~/.claude.json` holds the
`oauthAccount`/onboarding record, and claude-code re-runs login when it's
missing — the token in `~/.claude/.credentials.json` alone is not enough. So
every new sandbox prompted for login.

Fix: seed each sandbox with a **copy** of the host file at launch instead of a
bind. A launch-time copy is immune to the rename race, the in-sandbox file is a
regular file (claude-code's own rename-rewrites work — they'd EBUSY on a
single-file bind mountpoint), and sandbox writes still never touch host state.

- bubblewrap: `exec 11< ~/.claude.json` + `--perms 0600 --file 11 <dest>`
  (bwrap writes fd contents into the tmpfs HOME; fd pins a consistent snapshot)
- container: `cp` into the ephemeral container root, same pattern as .Xauthority
- VM: restored the meta-dir copy-in that 3b285ad had removed
- spec checklist updated

Verified in a live bubblewrap sandbox: file present with `oauthAccount`, 0600,
and atomic rename over it succeeds. `.#sandbox` and `.#container` build clean.
`.#vm` still fails on the pre-existing unrelated `virtualisation.vlans` nixpkgs
regression (option removed upstream) — VM edit verified by inspection + parse.

New skill file: `claude-json-login-state-copy-seeding-vs-bind-mount.md`.

## 2026-07-22 — /copy clipboard doesn't reach host from sandbox: add xclip

Report: `/copy` inside a sandbox never fills the host X CLIPBOARD (works
unsandboxed). Initial diagnosis went wrong twice, worth recording:

1. Guessed OSC 52 + nested-tmux swallowing it; added set-clipboard/
   terminal-features to the sandbox tmux.conf. Wrong: `--tmux` isn't the
   default, so it didn't explain the failure.
2. "Confirmed" the host has no clipboard binaries by running `command -v
   xclip` etc. — but that shell is itself sandboxed, so it measured the
   sandbox, not the host. Invalid premise. (User: "you have no ability in
   checking the absence of tool on the host system.") User then confirmed
   they DO have xclip on the host.

Real mechanism (from the claude-code binary's own strings): `/copy` shells
out to a clipboard binary — xclip/xsel (X11), wl-copy (Wayland), pbcopy
(macOS) with `-selection clipboard`. It never uses OSC 52. The sandbox
forwards DISPLAY + X socket + Xauthority but shipped no clipboard binary,
so claude had nothing to exec and fell back to the file.

Fix: add `xclip` to spec.packages. Reverted the pointless tmux.conf edit.

Verified in a real sandbox shell: `printf hello | xclip -selection
clipboard` exits 0 and `xclip -selection clipboard -o` reads `hello` back —
a full round-trip through the host X CLIPBOARD selection. (Final /copy
confirmation is the user's, since I can't observe their clipboard.)

New skill: claude-code-copy-clipboard-needs-xclip-in-sandbox.md — includes
the "can't probe host tools from inside the sandbox" lesson.

## 2026-07-22 — Sandbox self-awareness notice + optional project-dir / -- CLI

Two related CLI/UX changes across all three backends.

**Sandbox notice (agent self-awareness).** After an agent (me) twice reasoned
about the host from inside a sandbox — running `command -v xclip` etc. and
treating the result as host truth — added a notice injected into every
sandboxed claude session's system prompt via `claude --append-system-prompt`.
The string lives once in `sandbox-spec.nix` as `sandboxNotice = backend: "...";`
and each backend passes it (interpolated with its backend name). It tells the
agent the host filesystem/PATH/tools are not visible and not to infer host
state from in-sandbox commands. Also set machine-detectable env vars
`CLAUDE_SANDBOX=1` and `CLAUDE_SANDBOX_BACKEND=<name>` (bwrap --setenv,
nspawn --setenv, VM environment.variables) for hooks/scripts/PS1.

**Optional project-dir + `--` separator.** project-dir was a required
positional though it's almost always `.`. Reworked the parser in all three
backends: project-dir now defaults to `.`, and everything after `--` is passed
verbatim to claude (usual convention). Backward compatible — the manager
invokes `claude-sandbox {project_dir}` positionally and nobody passed trailing
claude args, so existing callers are unaffected. Unknown leading `-*` options
now error with a hint to use `--`.

Verified (bubblewrap, real runs): `--help` exits 0 with new usage; `--bogus`
rejected; bare invocation defaults to cwd; `CLAUDE_SANDBOX*` env present;
`claude-sandbox <dir> -- --version` runs `claude --version` inside (prints
2.1.217) — confirming `--append-system-prompt` + claude_args passthrough.
container builds (shellcheck clean); vm parses and still fails only on the
pre-existing unrelated virtualisation.vlans regression.

## 2026-07-25 — per-project state dir + `--enter`

Driven by the Claude Code usage report, whose largest friction bucket is
"Sandbox and PATH environment mismatches". Measured it inside a live sandbox:
`sed awk xargs jq curl diff patch make tar gzip less which file` were all
absent, and `grep`/`find` only *appeared* to work because claude-code injects
them as bash functions wrapping its own binary — so scripts and subprocesses
broke while interactive use looked fine. Shipped the real userland plus pip
(`python3` was already there; `ensurepip` was the actual hole).

Then moved sandbox state out of the project dir. Three things were writing
there: `.tmux/`, `.config/chromium/` (a whole browser profile, cookies and
all) and the container machine name. Now under
`${XDG_STATE_HOME}/claude-code-nix-sandbox/projects/<basename>-<hash>/`.

Naming went through two dead ends worth recording:

1. Argued for a hash on the grounds that directory names feed a length-limited
   syscall, budgeting against `sun_path` (108). **Wrong premise.** chromium
   binds its singleton socket in a unique temp dir and only symlinks it into
   the profile (`process_singleton_posix.cc:1042,1056,1060,1068`), explicitly
   to avoid long paths. The premise came from our own skill file, which has
   now been corrected. The hash stayed anyway — the plain slash-to-hyphen
   mangle is not injective — but for the right reason.
2. Kept the readable basename as a prefix per user request; direnv's trick of
   storing the plaintext path *inside* (`rc.go:386`) gives discoverability and
   doubles as a collision detector.

`--enter` joins a running sandbox's namespaces unprivileged. Works because we
own the user namespace bwrap created. Four gotchas, all found by testing:
open every ns fd before the first setns (post-join lookups fail ENOENT, not
EPERM); `setns` does not move the root dir; bwrap's `child-pid` is an
intermediate whose root is the `newroot`/`oldroot` staging tree, solved by
having the sandbox self-register from inside; and `--preserve-credentials` is
mandatory since bwrap denies setgroups. Also had to replay the payload's
environment from `/proc/<pid>/environ` — nsenter inherits the *caller's*.

Singleton-by-default was the actual request and is implemented, but is NOT
enabled: claude fails in a joined namespace with a bun ENOENT while git,
python, node and bun all work there. Environment, credentials, cwd, ns inode
and `/proc/self/exe` are all verified identical between founded and joined, so
the cause is still unknown. Shipping a default that breaks ordinary launches
was not acceptable, so joining is opt-in until that is understood; the switch
is one condition.

Data point that settled the singleton-safety question: across the user's own
history, same-project session overlap is ~nil (2 pairs, both <=2 min, both in
the `-home-jhhuh` pseudo-project). The 34% multi-clauding figure in the report
counts overlap across *different* projects.

## 2026-07-25 (later) — nix-ld and persistent ~/.local

nix-ld was broken in the worst way: NIX_LD and NIX_LD_LIBRARY_PATH leaked in
from the host pointing at /run/current-system, which is a tmpfs here, and
/lib64 did not exist at all — so everything advertised nix-ld as available and
nothing backed it. Both vars are now set to store paths, which also makes the
sandbox independent of the host's nix-ld setup.

Delivery differs per backend, and the container one is a trap:
programs.nix-ld.enable installs the /lib64 symlink via systemd-tmpfiles, but
that backend runs its entrypoint under --as-pid2 without booting systemd, so
the option would be a silent no-op. Symlinks are created explicitly there. The
VM boots systemd, so the option is genuinely sufficient.

Verified with a negative control rather than just a positive one: a Nix binary
repatched to the FHS interpreter fails in a pre-change sandbox and runs after.
Without the negative half the test proves nothing about the mechanism.

Persistent ~/.local hit a self-inflicted collision worth remembering. Binding
$state_dir/local over ~/.local shadows the state dir itself, because the state
dir *is* ~/.local/state/claude-code-nix-sandbox/... — the bind hid the mount
underneath and the registry write started failing with ENOENT. Fixed by
binding bin, lib and share individually, which leaves ~/.local/state intact.
bin alone would not do: pip splits a --user install across bin/ and
lib/pythonX.Y/site-packages.

Two findings about python that shipping pip does NOT fix:
- nixpkgs python marks itself externally managed (PEP 668), so plain
  `pip install --user` needs --break-system-packages.
- More decisively, it is built with user site-packages DISABLED, so --user
  fails outright regardless. The working paths are a venv or --prefix.
  Verified persistence with a venv under ~/.local/lib symlinked into
  ~/.local/bin, plus a plain script; both survive a fresh sandbox.

Also corrected spec.persistenceNotice, which claimed the entire home directory
was ephemeral. That was already false as of the state-dir commit and actively
misleading once ~/.local persisted — the notice exists precisely to stop work
being written somewhere that vanishes.

## 2026-07-25 (later still) — the bun ENOENT was nsenter --wd

Solved the blocker that kept singleton-by-default disabled, and it was never a
bun bug. `strace` (newly shipped) named it in one run: the trace tail is a
`".."` walk, i.e. a userspace getcwd() climbing to the root.

`nsenter --wd=<dir>` leaves the cwd unreachable from the chroot root nsenter
installs, so getcwd(2) fails ENOENT — while /proc/self/cwd still resolves
correctly. bun single-file executables call getcwd at startup; git/python/node
and bun itself do not, which is exactly why only claude appeared broken and
why the diagnosis went sideways for so long.

The false signal that cost the most: checking cwd with `pwd` in bash. Bash
prints $PWD from the environment and never calls getcwd, so it reported the
right directory while the syscall was broken. Verify syscalls with something
that actually makes the syscall.

Fix is to drop --wd and `cd` after entry, so the path resolves against the new
root. Singleton-by-default is now on: a second invocation in a project joins
the running sandbox and claude runs there normally. Found a follow-on bug while
verifying — `--new` was self-registering and hijacking the singleton slot, so
the original sandbox became undiscoverable once the --new one exited.

Also closed two loops the advisor flagged: strace can genuinely ptrace inside
the sandbox (not a hollow claim in the commit message), and `claude doctor`
inside the sandbox reports "No installation issues found", which answers the
original ~/.local/bin question directly rather than by assertion.

## 2026-07-25 (VM) — the VM backend was entirely broken, in two ways

Adding a state dir to the VM turned up two pre-existing bugs that together
meant the backend could not have worked at all.

**1. `virtualisation.vlans` blocked every build.** I had repeatedly written
this off as "a pre-existing unrelated nixpkgs regression" and used it to
justify shipping VM changes verified by parse only. That was wrong, and the
error message said so all along: it named our own flake as the definition
site. `vlans` belongs to the NixOS test framework, not qemu-vm.nix, and a
`mkIf` with a false condition still requires the option to exist. One-line
fix, and `.#vm` builds. Lesson: read the error, do not pattern-match it to a
story about someone else's bug.

**2. No 9p share ever reached the guest.** All seven were declared with
`fileSystems."..."`, but qemu-vm.nix replaces that whole attrset via
`mkVMOverride`, so they were silently dropped — no error, no warning. The
generated guest fstab contained only nixpkgs' own nix-store/shared/xchg. That
means no project dir, no ~/.claude, and no /mnt/meta, which is where the
launcher writes the entrypoint. Fixed by using `virtualisation.fileSystems`.
Checkable without booting: grep the built system's /etc/fstab for 9p lines.

This is a good argument for the VM being in `nix flake check`; it rotted
precisely because nothing exercised it.

The state dir itself follows the other backends: ~/.local/{bin,lib,share} on a
writable 9p share at /mnt/state, symlinked into the reconstructed host home.
Symlinks are safe here — the bind-mount requirement documented for the project
dir exists because getcwd() resolves symlinks and the path is encoded into
session state, which does not apply to ~/.local. The chromium profile is
deliberately not persisted for the VM: it runs stock chromium, which ignores
CHROMIUM_USER_DATA_DIR, and a SQLite profile over 9p invites locking trouble.

Runtime verification: CONFIRMED by the user on the host (booting needs
/dev/kvm, which is not exposed to this sandbox, so it could not be done from
inside). In a booted VM, /mnt/state/local lists bin/lib/share, ~/.local/bin
resolves through the symlink, PATH ends in the HOST home's .local/bin, and the
shell prompt shows the project at its host path — so the 9p shares mount, the
meta-dir path reconstruction runs, and the project bind-mount lands correctly.
That also confirms the two fixes above at runtime, not just in the generated
config: the VM now boots and mounts, which it demonstrably could not do
before.
Also note the remote builder fails the initrd derivation with
"/setup: No such file or directory"; `--builders ''` works.

## 2026-07-25 (tooling) — plugin-assumed tools, grounded in a scan

A plugin assumed `uv` existed. Rather than guess at a list, scanned
~/.claude/plugins for external command references: uv 57, jq 65, shellcheck
10, shfmt 8, delta 83, just 80, dot 21, parallel 22 (counts include prose
false positives, but the signal is clear). Shipped tier 1+2 from that plus a C
toolchain.

`uv` matters more than "another tool". It is the actual fix for the Python
situation found earlier: nixpkgs python is PEP 668 externally-managed AND
built with user site-packages disabled, so `pip install --user` cannot work at
all. uv manages its own venvs and installs into ~/.local, which the per-project
state dir now persists. Verified end to end: `uv tool install cowsay` lands in
~/.local/bin and still runs in a fresh sandbox.

Also shipped gcc/binutils/pkg-config. nix-ld lets prebuilt native binaries
run, but an npm install with no prebuilt artifact falls back to node-gyp,
which has to compile. Verified gcc actually compiles and runs a binary, not
merely that the command resolves — the multi-output trap means a package can
be in the closure while its CLI is not on PATH, so every one of the 32 new
tools was checked with `command -v` inside a real sandbox.

Deliberately not shipped: docker/podman (no daemon, and nesting is its own
project), language toolchains and cloud CLIs (these belong in the project's
devShell — `nix develop` works inside the sandbox because the nix daemon
socket is forwarded — and cloud CLIs raise credential-forwarding questions),
ffmpeg/texlive (heavy, rare). The backends already expose `extraPackages` for
per-user additions without touching the spec.

## Open: runtime verification deferred

Two features are build-verified only, deferred by agreement. Neither can be
exercised from inside the bubblewrap sandbox.

- `claude-sandbox-container --enter` / `--stop` — needs sudo and nspawn.
  Uses nsenter against the machine leader plus setpriv, deliberately NOT
  `machinectl shell`: that requires the container's own systemd, and this
  backend runs bash under `--as-pid2` without booting it.
- `claude-sandbox-vm --enter` — needs KVM (`/dev/kvm` is not bound into the
  sandbox). Attaches with socat to a second serial console (ttyS1) backed by a
  Unix socket in the state dir.

Treat the VM one as unproven in particular: that backend had two independent
fatal bugs this session (virtualisation.vlans blocking every build, and every
9p share silently dropped by mkVMOverride), so it has little track record.

What IS runtime-verified: bubblewrap `--enter`, the singleton, the state dir,
nix-ld, the persistent ~/.local, and the VM's 9p mounts and ~/.local (the
latter confirmed by the user on the host).

## 2026-07-28 — vision work, paused with a handoff

Stepped back from features to ask what the project is for long-run. Captured
in `artifacts/plan_project-vision.md`; paused before writing a formal spec, so
that file is a draft and not an approved design.

Five decisions: personal daily driver now expandable to agent-fleet
infrastructure; local and remote on one substrate; hybrid identity (instances
real, project dir an alias); substrate-first with the manager frozen rather
than deleted or revived; and full decoupling from Claude Code via per-agent
adapters, under the user's constraint that upgrading the agent must not
require rebuilding the manager.

The measurement that mattered most: `nix path-info -r ./result-manager` shows
claude-code inside the manager's closure, via claude-sandbox →
claude-sandbox-path. Since the manager is a systemd daemon with its store path
baked into ExecStart, bumping the agent today restarts a live supervisor. That
turned "agent is a parameter, not a build dependency" from a preference into a
requirement.

Also surfaced: the manager's state.json and the sandbox's new ns registry are
two rival answers to "what is running", and they are semantically
incompatible — the manager assumes it spawned a fresh instance while
`claude-sandbox <dir>` now joins the project's existing one. That contradiction
was introduced this session by the singleton change and is unresolved.

## 2026-09-20 — VM shares: 9p → virtiofs for SQLite WAL

omp would not start in the VM: `SQLITE_IOERR_SHMMAP` opening
`~/.omp/agent/agent.db`. Root cause: every omp DB is WAL-mode SQLite, WAL's
wal-index is a shared mmap of the `-shm` file, and 9p cannot mmap shared
files (cross-host WAL is categorically unsupported; see omp#9082).

Swapped all VM shares to virtiofs: guest fstab entries become
`fsType = "virtiofs"` (tags unchanged, still `virtualisation.fileSystems` —
mkVMOverride), and the launcher spawns one virtiofsd per share with sockets
in the per-launch meta dir (state-dir paths overflow sockaddr_un's 108
chars — first boot attempt failed exactly there). Each daemon attaches as
`vhost-user-fs-pci`; no memfd work needed because the generated run script
already provides `-object memory-backend-memfd,id=mem0,share=on -machine
memory-backend=mem0` and runs its own daemons for nix-store/xchg/shared —
my initial duplicate backend would have double-set `memory-backend=`.
rw shares get `--writeback`, ro shares `--readonly` + guest `ro`.

Runtime-verified under nested TCG (no /dev/kvm here): both VMs booted, all
shares mounted; sqlite WAL probe on a scratch DB inside the virtiofs
`~/.omp` mount passed (`journal_mode=wal`, insert/select through the mmap'd
shm, clean close checkpointed -wal/-shm away) — the exact operation that
died under 9p. Multi-VM: two VMs sharing the host `~/.omp` ran three
concurrent `BEGIN IMMEDIATE` writer processes (20 txns each) through their
own virtiofsd daemons: 60/60 rows, `integrity_check ok` from both guests.
`vm-mounts` check now asserts `virtiofs` fstab lines.
