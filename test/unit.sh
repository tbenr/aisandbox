#!/bin/bash
#
# Offline tests of the CLI: no VM, no network, nothing of yours is touched.
#
# `orb` is replaced by a stand-in (test/fake-orb) that knows one machine,
# which is stopped, and the tool's state directory is a scratch one. What is tested is everything
# the CLI does before it needs the VM: the tunnel registry, option checking,
# user inference, notes, mounts.

. "$(dirname "$0")/lib.sh"
make_tmp
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/share one" "$TMP/keys"
FAKE_LOG=$TMP/orb.log
: > "$FAKE_LOG"
cat > "$TMP/orb.config" <<EOF
machine.FakeBox.forward_ssh_agent: false
machine.FakeBox.isolate_network: true
machine.FakeBox.isolated: true
machine.FakeBox.mounts: /Users/someone/alpha:/Users/someone/alpha,/Users/someone/beta
machine.FakeBox.username: agentuser
machines.expose_ports_to_lan: false
EOF
# The stand-in for orb (test/fake-orb) keeps what it knows and records there.
export FAKE_DIR=$TMP
cp "$(dirname "$0")/fake-orb" "$TMP/bin/orb"
# An ssh configuration in which the login user depends on the environment,
# reached through a stub so that your own ~/.ssh/config is not involved.
cat > "$TMP/ssh_config" <<'EOF'
Match host i-0user exec "test \"$AISB_TEST_USER\" = dev"
  User devuser
Host i-0user
  HostName 127.0.0.1
  Port 9
  User defaultuser
EOF
cat > "$TMP/bin/ssh" <<EOF
#!/bin/sh
case " \$* " in *" i-0user "*) exec $REAL_SSH -F "$TMP/ssh_config" "\$@" ;; esac
exec $REAL_SSH "\$@"
EOF
chmod +x "$TMP/bin/orb" "$TMP/bin/ssh"
echo dummy > "$TMP/keys/id key"

CONF=$TMP/home/tunnels.conf
a() { env PATH="$TMP/bin:$PATH" AISANDBOX_HOME="$TMP/home" AISANDBOX_MACHINE=FakeBox "$AISB" "$@" 2>&1; }
rc() { a "$@" >/dev/null; echo $?; }
field() { awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }' "$CONF"; }   # field <tunnel> <column>

section "syntax"
is "aisandbox parses" "$(zsh -n "$AISB" 2>&1)" ""
is "vm/provision.sh parses" "$(bash -n "$REPO/vm/provision.sh" 2>&1)" ""
is "vm/sharecheck.sh parses" "$(bash -n "$REPO/vm/sharecheck.sh" 2>&1)" ""

section "basics"
like "help lists the tunnel command" "$(a help)" "aisandbox tunnel add"
is "an unknown command fails" "$(rc frobnicate)" "1"
like "status of a stopped VM says so" "$(a status)" "FakeBox +stopped"
is "doctor refuses without a running VM" "$(rc doctor)" "1"
is "tunnel up refuses without a running VM" "$(rc tunnel up)" "1"

section "tunnel add: an ssh target"
out=$(a tunnel add box alice@example.invalid --port 2300)
like "reports the new tunnel" "$out" "Added tunnel 'box': VM port 2300 -> alice@example.invalid \(login as alice\)"
like "says it opens at the next up, the VM being down" "$out" "opened by the next: aisandbox up"
is "registry line" "$(grep '^box|' "$CONF")" "box|ssh|alice@example.invalid|2300|alice|22|1|||"
is "the same name again is refused" "$(rc tunnel add box bob@example.invalid)" "1"
like "and says why" "$(a tunnel add box bob@example.invalid)" "already exists"

section "tunnel add: options"
a tunnel add full carol@example.invalid --port 2301 --remote-port 2022 --no-auto \
	-i "$TMP/keys/id key" --env AWS_PROFILE=dev --env AWS_REGION=eu-west-1 --note "archive node, read-only" >/dev/null
is "remote port" "$(field full 6)" "2022"
is "--no-auto" "$(field full 7)" "0"
is "identity stored as an absolute path, spaces kept" "$(field full 8)" "$(cd "$TMP/keys" && pwd -P)/id key"
is "--env repeated, joined" "$(field full 9)" "AWS_PROFILE=dev,AWS_REGION=eu-west-1"
is "note" "$(field full 10)" "archive node, read-only"

section "tunnel add: what is refused"
is "a name with a slash" "$(rc tunnel add 'bad/name' x@example.invalid)" "1"
is "a name longer than 24 characters" "$(rc tunnel add abcdefghijklmnopqrstuvwxyz x@example.invalid)" "1"
is "--env without NAME=VALUE" "$(rc tunnel add e1 x@example.invalid --env novalue)" "1"
is "--env with a space in the value" "$(rc tunnel add e2 x@example.invalid --env 'A=b c')" "1"
is "--env with a comma in the value" "$(rc tunnel add e3 x@example.invalid --env 'A=b,c')" "1"
is "a note containing |" "$(rc tunnel add n1 x@example.invalid --note 'a | b')" "1"
is "an identity file that does not exist" "$(rc tunnel add i1 x@example.invalid -i "$TMP/keys/missing")" "1"
is "a port already taken by another tunnel" "$(rc tunnel add p1 x@example.invalid --port 2300)" "1"
is "the port of the tunnel sshd" "$(rc tunnel add p2 x@example.invalid --port 2222)" "1"
is "a port below 1024" "$(rc tunnel add p3 x@example.invalid --port 80)" "1"
is "--direct together with -i" "$(rc tunnel add d1 --direct example.invalid:22 -i "$TMP/keys/id key")" "1"
is "--direct together with an ssh target" "$(rc tunnel add d2 x@example.invalid --direct example.invalid:22)" "1"
is "--direct without a port" "$(rc tunnel add d3 --direct example.invalid)" "1"
is "none of the refused ones was registered" "$(grep -c -E '^(bad|abcdef|e[123]|n1|i1|p[123]|d[123])' "$CONF")" "0"

section "tunnel add: --direct"
a tunnel add direct1 --direct example.invalid:2222 --port 2302 >/dev/null
is "kind and target" "$(field direct1 2) $(field direct1 3)" "direct example.invalid:2222"
is "logs in as the agent user by default" "$(field direct1 5)" "agentuser"

section "tunnel add: ports handed out automatically"
a tunnel add auto1 x@example.invalid >/dev/null
a tunnel add auto2 x@example.invalid >/dev/null
p1=$(field auto1 4); p2=$(field auto2 4)
like "a port from 2200 up" "$p1" '^2[2-9][0-9][0-9]$'
if [ "$p1" != "$p2" ] && [ "$p1" != 2300 ] && [ "$p2" != 2300 ] && [ "$p1" != 2301 ] && [ "$p2" != 2302 ]; then pass "never one that is taken ($p1, $p2)"; else fail "handed out a port twice ($p1, $p2)"; fi

section "tunnel add: the login user is inferred the way the tunnel will connect"
a tunnel add envuser i-0user --port 2310 --env AISB_TEST_USER=dev >/dev/null
a tunnel add plainuser i-0user --port 2311 >/dev/null
is "with --env, the ssh config's Match exec applies" "$(field envuser 5)" "devuser"
is "without it, the default user" "$(field plainuser 5)" "defaultuser"
a tunnel add given i-0user --port 2312 --user explicit >/dev/null
is "--user wins over inference" "$(field given 5)" "explicit"

section "tunnel ls"
out=$(a tunnel ls)
like "lists a tunnel with its port and state" "$out" "box +2300 +alice@example.invalid +alice +yes +down"
like "shows the note" "$out" "note: archive node, read-only"
like "shows how the Mac logs in" "$out" "Mac login: key .*id key +env AWS_PROFILE=dev AWS_REGION=eu-west-1"

section "tunnel note"
out=$(a tunnel note box what this machine is)
like "saved on the Mac while the VM is down" "$out" "saved on the Mac"
is "stored" "$(field box 10)" "what this machine is"
a tunnel note box >/dev/null
is "no text clears it" "$(field box 10)" ""
is "a note with | is refused" "$(rc tunnel note box 'a | b')" "1"
is "a note for an unknown tunnel is refused" "$(rc tunnel note nosuch text)" "1"

section "tunnel rm"
is "removing works" "$(rc tunnel rm plainuser)" "0"
is "it is gone from the registry" "$(grep -c '^plainuser|' "$CONF")" "0"
is "the others are still there" "$(grep -c '^envuser|' "$CONF")" "1"
is "removing an unknown tunnel fails" "$(rc tunnel rm nosuch)" "1"

section "shared folders"
out=$(a mount ls)
like "one at its Mac path is listed plainly" "$out" "^ +/Users/someone/alpha$"
like "one that is elsewhere in the VM says where" "$out" "/Users/someone/beta +\\(in the VM: /mnt/mac/Users/someone/beta\\)"
like "status shows the same" "$(a status)" "stopped"
a mount add "$TMP/share one" >/dev/null
like "mount add registers the absolute path (the VM being down, to be moved by the next up)" "$(cat "$FAKE_LOG")" "config-change: config add machine.FakeBox.mounts $(cd "$TMP/share one" && pwd -P)\$"
is "mount add of a missing folder fails" "$(rc mount add "$TMP/no such folder")" "1"
mkdir -p "$TMP/has:colon"
is "a path with a colon is refused (OrbStack could not tell it from SOURCE:DEST)" "$(rc mount add "$TMP/has:colon")" "1"
a mount rm /Users/someone/alpha >/dev/null
like "mount rm removes the entry as it is configured" "$(cat "$FAKE_LOG")" "config-change: config remove machine.FakeBox.mounts /Users/someone/alpha:/Users/someone/alpha\$"
is "mount rm of a folder that is not shared fails" "$(rc mount rm /Users/someone/gamma)" "1"

section "what agents are told: tunnels, and shared folders as the VM has them"
# From here the stub plays a running VM, so that the CLI publishes.
run() { env FAKE_RUNNING=1 PATH="$TMP/bin:$PATH" AISANDBOX_HOME="$TMP/home" AISANDBOX_MACHINE=FakeBox "$AISB" "$@" 2>&1; }
doc() { cat "$TMP/vm.CLAUDE.md"; }
printf 'ok\t/Users/someone/alpha\t/Users/someone/alpha\nok\t/Users/someone/beta\t/mnt/mac/Users/someone/beta\nfailed\t/Users/someone/gone\t/Users/someone/gone\n' > "$TMP/vm.status"
out=$(run tunnel note box "build server, read-only")
like "the note is reported as visible to agents" "$out" "note set for box; agents see it"
like "a tunnel with its note" "$(doc)" '^\| `box` \| alice \| build server, read-only \|$'
like "a tunnel without one" "$(doc)" '^\| `envuser` \| devuser \| \(no description given\) \|$'
like "how to use them" "$(doc)" 'Run `sandbox-tunnels` to see which of them are open'
unlike "not the text for when there are none" "$(doc)" "No remote machines are available"
like "a folder at its Mac path" "$(doc)" '^- `/Users/someone/alpha`$'
like "under the heading that says worktrees carry over" "$(doc)" "git worktrees work across them"
like "a folder at another path, with both paths" "$(doc)" '^- `/mnt/mac/Users/someone/beta` \(on the Mac: `/Users/someone/beta`\)$'
like "under the heading that says they do not" "$(doc)" "do not carry over between the Mac and this VM"
unlike "a folder that is not mounted is not mentioned" "$(doc)" "/Users/someone/gone"
like "the machine's name is filled in" "$(doc)" 'This machine is "FakeBox"'
unlike "no template syntax is left" "$(doc)" '<!--|\{\{|\}\}'
is "the agents' tunnel list has the note" "$(grep '^box|' "$TMP/vm.tunnels")" "box|2300|alice|build server, read-only"
like "the agents' ssh config has the tunnel" "$(cat "$TMP/vm.sshconf")" "Host box"

printf 'failed\t/Users/someone/alpha\t/Users/someone/alpha\n' > "$TMP/vm.status"
run tunnel note box "build server, read-only" >/dev/null
unlike "with no folder mounted, none is announced" "$(doc)" "These folders are shared|same path here|different path here"
like "the rest of the files section is still there" "$(doc)" "Commits you make here are unsigned"

section "what agents are told when there are no tunnels"
for t in box full direct1 auto1 auto2 envuser given; do run tunnel rm $t >/dev/null; done
is "the registry is empty" "$(grep -vc '^#' "$CONF")" "0"
like "says there are none and how they come to exist" "$(doc)" "No remote machines are available at the moment"
unlike "no table, no usage notes" "$(doc)" 'Login user|Run `sandbox-tunnels` to see which'
unlike "no template syntax is left" "$(doc)" '<!--|\{\{|\}\}'

section "the instruction file is never replaced by an empty one"
mkdir -p "$TMP/copy/vm" && cp "$AISB" "$TMP/copy/" && cp "$REPO/vm/sharecheck.sh" "$TMP/copy/vm/"     # no template in this copy
env PATH="$TMP/bin:$PATH" AISANDBOX_HOME="$TMP/home" AISANDBOX_MACHINE=FakeBox "$AISB" tunnel add keep x@example.invalid --port 2390 >/dev/null 2>&1
before=$(cksum < "$TMP/vm.CLAUDE.md")
out=$(env FAKE_RUNNING=1 PATH="$TMP/bin:$PATH" AISANDBOX_HOME="$TMP/home" AISANDBOX_MACHINE=FakeBox "$TMP/copy/aisandbox" tunnel note keep something 2>&1); rc=$?
is "publishing fails when the text cannot be generated" "$rc" "1"
like "and says agents do not see the change" "$out" "could not be written to the VM"
is "the instructions in the VM are untouched" "$(cksum < "$TMP/vm.CLAUDE.md")" "$before"

section "shared folders, as the VM has them"
setshares() { sed -i '' "s|^machine.FakeBox.mounts: .*|machine.FakeBox.mounts: $1|" "$TMP/orb.config"; }
setshares "/repo:/repo"
printf 'ok\t/repo\t/repo\n' > "$TMP/vm.status"
out=$(run mount ls); rc=$?
is "exactly one shared folder: exit status" "$rc" "0"
like "it is listed as mounted" "$out" '^ +/repo$'
unlike "and is not miscounted (one line is not eleven folders)" "$out" "answered for"
setshares "/a:/a,/b,/c:/c"
printf 'ok\t/a\t/a\nfailed\t/b\t/mnt/mac/b\nok\t/c\t/c\n' > "$TMP/vm.status"
out=$(run mount ls)
like "one that is not mounted is marked" "$out" '/b +\(in the VM: /mnt/mac/b\) +NOT MOUNTED'
like "the others are plain" "$out" '^ +/c$'
printf 'ok\t/a\t/a\n' > "$TMP/vm.status"
like "an answer that leaves folders out is called that" "$(run mount ls)" "the VM answered for 1 of 3 shared folders"
rm -f "$TMP/vm.status"
out=$(run mount ls); rc=$?
is "no answer at all: exit status" "$rc" "1"
like "and it says the VM could not be asked" "$out" "could not ask the VM"

section "removing a shared folder removes every entry for it"
setshares "/dup,/dup:/dup,/other:/other"
out=$(a mount rm /dup); rc=$?
is "a folder registered twice: exit status" "$rc" "0"
is "both entries are gone, the other folder stays" "$(grep '^machine.FakeBox.mounts' "$TMP/orb.config")" "machine.FakeBox.mounts: /other:/other"
setshares "/dup,/dup:/dup"
out=$(FAKE_REMOVE_FAILS=1 a mount rm /dup); rc=$?
is "if OrbStack does not remove it: exit status" "$rc" "1"
like "it says the folder is still available to the VM" "$out" "/dup is still registered"
unlike "and does not say removed" "$out" "removed /dup"

section "a configuration that cannot be read proves nothing"
shares_line() { grep '^machine.FakeBox.mounts' "$TMP/orb.config"; }
setshares "/dup,/dup:/dup"
rm -f "$TMP/changed"
out=$(FAKE_REMOVE_FAILS=1 FAKE_SHOW_FAILS_AFTER_CHANGE=1 a mount rm /dup); rc=$?
is "mount rm, removal and the check afterwards both failing: exit status" "$rc" "1"
unlike "it does not say removed" "$out" "removed /dup"
like "it says the removal could not be confirmed" "$out" "could not confirm the removal.*may still be available to the VM"
is "and the folder is indeed still shared" "$(shares_line)" "machine.FakeBox.mounts: /dup,/dup:/dup"
rm -f "$TMP/changed"
out=$(FAKE_SHOW_FAILS_AFTER_CHANGE=1 a mount rm /dup); rc=$?
is "mount rm, removal working but not checkable: exit status" "$rc" "1"
unlike "it still does not claim removal" "$out" "removed /dup"
out=$(FAKE_SHOW_FAILS=1 a mount rm /other); rc=$?
is "mount rm with the configuration unreadable from the start: exit status" "$rc" "1"
like "says nothing was changed" "$out" "could not be read; nothing was changed"
out=$(FAKE_SHOW_FAILS=1 a mount ls); rc=$?
is "mount ls: exit status" "$rc" "1"
like "mount ls does not say there are no shared folders" "$out" "not known which folders are shared"
setshares "/keep:/keep"
rm -f "$TMP/changed"
out=$(FAKE_SHOW_FAILS_AFTER_CHANGE=1 a mount add "$TMP/share one"); rc=$?
is "mount add that cannot be checked: exit status" "$rc" "1"
like "says it is not known whether it was added" "$out" "not known whether .* was added"
rm -f "$TMP/changed"
out=$(FAKE_ADD_FAILS=1 a mount add "$TMP/keys"); rc=$?
is "mount add that OrbStack refuses: exit status" "$rc" "1"
is "the existing shares are untouched" "$(shares_line | grep -c '/keep:/keep')" "1"
rm -f "$TMP/changed"

section "stayed offline"
is "the CLI never tried to reach the VM" "$(grep -c UNEXPECTED "$FAKE_LOG")" "0"

finish
