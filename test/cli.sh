#!/bin/bash
#
# Tests of how `aisandbox` reacts when the VM does not answer the way it
# should: a status query that fails or is incomplete, and writes into the VM
# that fail. The failures are produced by a stub `orb` that passes everything
# else through to the real one.
#
# Needs the VM running and set up. This suite runs the real `aisandbox up`
# several times. That does not restart the VM, but note:
#   - `up` opens every autostart tunnel that is not open, with your
#     credentials. To avoid doing that behind your back, the suite refuses to
#     start unless they are all open already (override: --allow-tunnels).
#   - while it runs, the agent instructions in the VM are rewritten more than
#     once (that is what is being tested). A final real `up` restores them,
#     also if the suite is interrupted.
# It adds and removes tunnels named aisbtest-* in your real tunnel list.

. "$(dirname "$0")/lib.sh"
need_vm

if [ "${1:-}" != --allow-tunnels ]; then
	closed=$("$AISB" tunnel ls | awk 'NF == 6 && $5 == "yes" && $6 != "up" { print $1 }' | tr '\n' ' ')
	if [ -n "$closed" ]; then
		echo "these autostart tunnels are not open: $closed"
		echo "'aisandbox up' would open them with your credentials. Open them first, or run: test/cli.sh --allow-tunnels"
		exit 2
	fi
fi

make_tmp
RESTORE=0
SHARE=
cleanup() {
	if [ -n "$SHARE" ]; then
		"$REAL_ORB" config remove "machine.$MACHINE.mounts" "$SHARE" >/dev/null 2>&1
		"$REAL_ORB" config remove "machine.$MACHINE.mounts" "$SHARE:$SHARE" >/dev/null 2>&1
	fi
	"$AISB" tunnel rm aisbtest-probe >/dev/null 2>&1
	"$AISB" tunnel rm aisbtest-probe2 >/dev/null 2>&1
	"$AISB" tunnel rm aisbtest-menu >/dev/null 2>&1
	"$AISB" tunnel rm aisbtest-plain >/dev/null 2>&1
	if [ "$RESTORE" = 1 ]; then "$AISB" up >/dev/null 2>&1; fi
	rm -rf "$TMP"
}
trap cleanup EXIT

FIRST_SHARE=$("$REAL_ORB" config show | awk -F': ' -v k="machine.$MACHINE.mounts" '$1 == k { print $2 }' | cut -d, -f1 | sed 's/:.*//')

# stub <name> <shell case body>: an `orb` that does something else for the
# calls the case body matches, and is the real orb for all others.
stub() {
	mkdir -p "$TMP/$1"
	cat > "$TMP/$1/orb" <<EOF
#!/bin/sh
case "\$*" in
$2
esac
exec "$REAL_ORB" "\$@"
EOF
	chmod +x "$TMP/$1/orb"
}
stub status-fails    '*"aisandbox-shares-status"*) exit 1 ;;'
stub status-partial  "*\"aisandbox-shares-status\"*) \"$REAL_ORB\" \"\\\$@\" | awk -F'\\t' -v s=\"$FIRST_SHARE\" '\\\$2 != s'; exit 0 ;;"
stub remove-fails    '"config remove "*) exit 1 ;;'
stub add-fails       '"config add "*) exit 1 ;;'
stub writes-fail     '*"cat > /etc/ssh/ssh_config.d/aisandbox.conf"*|*"cat > /etc/aisandbox/tunnels"*|*"cat > /etc/claude-code/CLAUDE.md"*) cat >/dev/null; exit 1 ;;'

with() { local s=$1; shift; env PATH="$TMP/$s:$PATH" "$AISB" "$@" 2>&1; }   # with <stub> <aisandbox args>
vm_state() { "$REAL_ORB" list | awk -v m="$MACHINE" '$1 == m { print $2 }'; }
RESTORE=1

section "up: the VM cannot be asked about the shared folders"
out=$(with status-fails up); rc=$?
is "exit status" "$rc" "1"
like "says so" "$out" "could not ask the VM whether the shared folders are mounted"
is "the VM is left running (this is not a hardening failure)" "$(vm_state)" "running"
out=$(with status-fails doctor); rc=$?
is "doctor fails too" "$rc" "1"
like "with one clear line" "$out" "FAIL +could not ask the VM"

if [ -n "$FIRST_SHARE" ]; then
	section "up: the answer leaves out a configured share"
	out=$(with status-partial up); rc=$?
	is "exit status" "$rc" "1"
	like "says the answer does not cover every share" "$out" "the VM answered for [0-9]+ of [0-9]+ shared folders"
	out=$(with status-partial doctor); rc=$?
	is "doctor fails for it" "$rc" "1"
else
	printf '\n  skip  no shared folder configured; the incomplete-answer test needs one\n'
fi

section "the tunnel information cannot be written into the VM"
"$AISB" tunnel add aisbtest-probe --direct 127.0.0.1:9 --user nobody --no-auto >/dev/null 2>&1
out=$(with writes-fail tunnel note aisbtest-probe some text); rc=$?
is "tunnel note: exit status" "$rc" "1"
like "tunnel note: says agents do not see it" "$out" "saved on the Mac, but could not be written to the VM"
is "tunnel note: indeed not in the VM" "$(agent sh -c 'grep "^aisbtest-probe|" /etc/aisandbox/tunnels' | tr -d '\r' | cut -d'|' -f4)" ""
out=$(with writes-fail tunnel add aisbtest-probe2 --direct 127.0.0.1:9 --user nobody --no-auto); rc=$?
is "tunnel add: exit status" "$rc" "1"
like "tunnel add: says agents cannot use it yet" "$out" "registered on the Mac, but the VM could not be updated"
out=$(with writes-fail tunnel rm aisbtest-probe2); rc=$?
is "tunnel rm: exit status" "$rc" "1"
like "tunnel rm: says the VM still lists it" "$out" "the VM could not be updated"
out=$(with writes-fail up); rc=$?
is "up: exit status" "$rc" "1"
like "up: warns about outdated information" "$out" "could not be updated; agents may see outdated information"
is "up: the VM is left running" "$(vm_state)" "running"
is "with the real orb, the note goes through" "$("$AISB" tunnel note aisbtest-probe some text >/dev/null 2>&1; echo $?)" "0"
is "and is in the VM" "$(agent sh -c 'grep "^aisbtest-probe|" /etc/aisandbox/tunnels' | tr -d '\r' | cut -d'|' -f4)" "some text"
is "removing the probe" "$("$AISB" tunnel rm aisbtest-probe >/dev/null 2>&1; echo $?)" "0"

section "a shared folder whose entry cannot be replaced cleanly"
# A scratch folder is registered the old way (at /mnt/mac). `up` wants to move
# it to its Mac path: add the new entry, remove the old one. First the add
# fails, then the removal. Nothing is mounted by any of this: that would take a VM restart.
mkdir -p "$TMP/share"
SHARE=$(cd "$TMP/share" && pwd -P)
shares() { "$REAL_ORB" config show | awk -F': ' -v k="machine.$MACHINE.mounts" '$1 == k { print $2 }'; }
"$REAL_ORB" config add "machine.$MACHINE.mounts" "$SHARE" >/dev/null 2>&1
before=$(shares)
out=$(with add-fails up); rc=$?
is "if the new entry cannot be added: exit status" "$rc" "1"
like "up says the entry could not be replaced" "$out" "could not replace the OrbStack entry of shared folder $SHARE"
is "and the folder keeps the share it had: nothing was removed" "$(shares)" "$before"
out=$(with remove-fails up); rc=$?
is "up: exit status" "$rc" "1"
like "up: says the entry could not be replaced" "$out" "could not replace the OrbStack entry of shared folder $SHARE"
unlike "up: does not report it as moved" "$out" "$SHARE: will be mounted at its Mac path"
unlike "up: does not restart the VM for it" "$out" "Restarting"
like "the folder is registered twice now, as the message says" "$(shares)" "(^|,)$SHARE,.*$SHARE:$SHARE(,|\$)|(^|,)$SHARE:$SHARE,.*$SHARE(,|\$)"
out=$("$AISB" mount rm "$SHARE" 2>&1); rc=$?
is "mount rm: exit status" "$rc" "0"
unlike "mount rm: no entry for the folder is left" "$(shares)" "$SHARE"
SHARE=

section "the menu: extra options with quotes"
if command -v expect >/dev/null 2>&1; then
	mkdir -p "$TMP/dir with space" && echo dummy > "$TMP/dir with space/key"
	cat > "$TMP/menu.exp" <<EOF
set timeout 120
log_user 0
spawn -noecho "$AISB"
expect "> "
send "5\r"
expect "Name for the tunnel"
send "aisbtest-menu\r"
expect "SSH target"
send "nobody@127.0.0.1\r"
expect "Extra options"
send -- "-i \"$TMP/dir with space/key\" --note \"two words\" --no-auto\r"
expect "Press Enter"
send "\r"
expect "> "
send "5\r"
expect "Name for the tunnel"
send "aisbtest-plain\r"
expect "SSH target"
send "nobody@127.0.0.1\r"
expect "Extra options"
send "\r"
expect "Press Enter"
send "\r"
expect "> "
send "q\r"
expect eof
EOF
	expect "$TMP/menu.exp" >/dev/null 2>&1
	conf=${AISANDBOX_HOME:-$HOME/.aisandbox}/tunnels.conf
	is "a quoted key path with spaces" "$(awk -F'|' '$1 == "aisbtest-menu" { print $8 }' "$conf")" "$(cd "$TMP/dir with space" && pwd -P)/key"
	is "a quoted note" "$(awk -F'|' '$1 == "aisbtest-menu" { print $10 }' "$conf")" "two words"
	is "no extra options at all" "$(awk -F'|' '$1 == "aisbtest-plain" { print $2 "|" $7 "|" $8 "|" $10 }' "$conf")" "ssh|1||"
	"$AISB" tunnel rm aisbtest-menu >/dev/null 2>&1
	"$AISB" tunnel rm aisbtest-plain >/dev/null 2>&1
else
	printf '  skip  expect is not installed\n'
fi

section "back to normal"
out=$("$AISB" up 2>&1); rc=$?
is "a real up succeeds" "$rc" "0"
RESTORE=0
is "doctor passes" "$("$AISB" doctor >/dev/null 2>&1; echo $?)" "0"
if [ -n "$FIRST_SHARE" ]; then
	like "the agent instructions list the shares again" "$(agent cat /etc/claude-code/CLAUDE.md)" "^- \`$FIRST_SHARE\`"
fi
is "no test tunnels are left" "$("$AISB" tunnel ls | grep -c aisbtest-)" "0"

finish
