# Tests

```bash
test/run            # unit, shares, git
test/run all        # those plus tunnel and cli
```

Each suite is a script that checks its own results and exits non-zero if
anything fails. They are plain bash (the one macOS ships) and need nothing
installed beyond OrbStack; `cli` uses `expect` for one section and skips it
if it is missing.

| Suite | Needs | What it touches |
|---|---|---|
| `unit` | nothing | Nothing of yours. `orb` is a stand-in with one machine, and the tool's state is a scratch directory. Tunnel registry, option checking, user inference, notes, shared folders, and what agents are told. |
| `shares` | VM running | Disposable paths in the VM (`/aisbtest`, `/tmp/aisb-atk`). The script under test only looks. Not your shared folders. |
| `git` | VM running | Throwaway repositories under `/tmp` in the VM. Your shared repositories are only read (one `git config` lookup each). |
| `tunnel` | VM running and set up | Starts a throwaway `sshd` on the Mac's loopback, port 22022. Adds and removes tunnels named `aisbtest-*` in your real tunnel list, so the tunnel information in the VM is rewritten. Your own tunnels are not opened, closed or changed. |
| `cli` | VM running and set up | Runs the real `aisandbox up` several times with a stub `orb` that makes single calls fail. Does not restart the VM. Refuses to start unless your autostart tunnels are open, because `up` would open them with your credentials. Rewrites the agent instructions in the VM and restores them at the end. |
| `disruptive` | — | **Stops and restarts the VM several times, closes your tunnels, ends agent sessions**, briefly removes the hardening to check that `up` restores it, and shares a scratch folder for a moment. Only runs with `AISB_TEST_DISRUPTIVE=yes`. Not part of `all`. |

## What is where

- `lib.sh` — the few helpers the suites share (`is`, `like`, `root`, `agent`).
- `fake-orb` — the stand-in for `orb` that the `unit` suite puts in `PATH`:
  one machine and no VM. Its header says what it plays and records.
- `git-vm.sh` — the half of the `git` suite that runs inside the VM. It is a
  file of its own because macOS's bash cannot parse a `case` inside a
  here-document inside `$(...)`.

## Rules the suites follow

- **Real repositories and shared folders are read, never written.** In
  particular `git worktree prune` is only ever run in a throwaway repository:
  if the guard under test were missing, running it in a real one would do
  exactly the damage the guard exists to prevent.
- **Everything a suite creates has a name that marks it** (`aisbtest-*`,
  `/aisbtest`, `/tmp/aisb-atk`) and is removed at the end, also when the
  suite fails or is interrupted.
- **Failures are provoked with stubs, not by breaking the real thing**, where
  that is possible: a stub `orb` or `ssh` earlier in `PATH` that
  fails one particular call and passes the rest through.
