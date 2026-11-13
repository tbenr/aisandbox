<!--# The instructions an agent gets at the start of every session in the VM.
<!--# `aisandbox` fills this in and writes it to /etc/claude-code/CLAUDE.md,
<!--# Claude Code's place for machine-wide instructions.
<!--#
<!--# It is written for a reader that knows nothing about this setup, and it
<!--# gives the reason for each limit, so that an agent works with the sandbox
<!--# instead of around it.
<!--#
<!--# Template syntax (see render_template in aisandbox):
<!--#   {{NAME}}             replaced by a value; alone on a line, the value
<!--#                        may span several lines
<!--#   <!-- if NAME -->     the lines up to "<!-- end -->" are kept only if
<!--#   <!-- else -->        NAME has a value; "else" gives the alternative
<!--#   <!-- end -->
<!--#   lines starting like this one are dropped
# You are working inside a sandbox VM

This machine is "{{MACHINE}}", a Linux VM on the user's Mac, set up so that an AI
agent can work freely without being able to reach the rest of their network.
This file is generated on the Mac by the `aisandbox` tool and is rewritten
whenever the setup changes. It describes what is available to you here.

## Remote machines you can reach

<!-- if TUNNELS -->
You can log in to the machines below with `ssh <name>`. Each name is an SSH
tunnel that the user opens from the Mac; authentication is already set up with
this VM's own key.

| Name | Login user | What it is |
|---|---|---|
{{TUNNELS}}

- Run `sandbox-tunnels` to see which of them are open right now.
- Use the names exactly as given, also with `scp` and `rsync`
  (`scp file <name>:path`). The machines' real addresses are not reachable
  from here, so there is nothing to gain from looking for them.
- A closed tunnel can only be opened by the user, on the Mac, with
  `aisandbox tunnel up <name>`. If you need one that is closed, say so and
  ask them. The same goes for a machine that is not in this list.
<!-- else -->
No remote machines are available at the moment. The user adds them on the Mac
(`aisandbox tunnel add <name> <ssh-target>`); `sandbox-tunnels` lists them
once they exist. If your task needs a remote machine, ask the user for one.
<!-- end -->

## Network

The public internet works. Everything private is blocked by a firewall: the
user's Mac, their local network and their VPN. A connection to a private
address (10.x, 172.16-31.x, 192.168.x, 100.64.x, link-local) is refused
immediately. That is the sandbox doing its job, not a fault to work around.
Remote machines are reached only through the tunnels above.

## No root

`sudo` is not available, on purpose. Install what you can in your home
directory. If you need a system package, ask the user to run this on the Mac:
`aisandbox root -- apt-get install -y <package>`

## Files and git

<!-- if SHARES -->
These folders are shared with the Mac. Changes you make in them appear on the
Mac immediately, and the other way round.

<!-- end -->
<!-- if SHARES_AT_MAC_PATH -->
At the same path here as on the Mac:

{{SHARES_AT_MAC_PATH}}

Because the path is the same on both sides, git worktrees work across them:
those the user created on the Mac inside these folders work here as they are,
and those you create here work on the Mac.

<!-- end -->
<!-- if SHARES_ELSEWHERE -->
At a different path here than on the Mac. Git worktrees store absolute paths,
so they do not carry over between the Mac and this VM for these:

{{SHARES_ELSEWHERE}}

<!-- end -->
- Commits you make here are unsigned and authored as the user. That is
  expected: the signing key stays on the Mac. Do not configure signing.
- This VM has no GitHub credentials, so `git push` will not work. Commit to
  a branch and tell the user its name; they push it from the Mac.
- `git worktree list` may mark some worktrees "prunable". Those live on the
  Mac outside the shared folders, so they only look missing from here; they
  are not. `git worktree prune` is disabled in this VM for that reason,
  because it would delete their metadata on the Mac.
