#!/bin/bash
#
# End-to-end test of a tunnel: the Mac logs in to a target with a key file and
# an environment variable, the port is delivered into the VM, and the agent
# logs in through it with the VM's key.
#
# Needs the VM running and set up. The "target" is a throwaway sshd started
# here on the Mac's loopback (port 22022) as your user; it accepts two keys
# and nothing else: a key made for this test (forwarding only) and the VM's
# key (which can only print a line). It is reachable solely through a
# ProxyCommand that refuses unless a variable is set, which is how an AWS SSM
# setup behaves. A stub `ssh` adds this test's ssh configuration for that one
# host, so your ~/.ssh/config and known_hosts are not involved.
#
# It adds and removes tunnels named aisbtest-* in your real tunnel list, and
# so rewrites the tunnel information in the VM. Your own tunnels are not
# opened, closed or changed.

. "$(dirname "$0")/lib.sh"
need_vm
make_tmp
PORT=22022
SSHD=

cleanup() {
	"$AISB" tunnel rm aisbtest-env >/dev/null 2>&1
	"$AISB" tunnel rm aisbtest-noenv >/dev/null 2>&1
	if [ -n "$SSHD" ]; then kill "$SSHD" 2>/dev/null; wait "$SSHD" 2>/dev/null; fi
	rm -rf "$TMP"
}
trap cleanup EXIT

if nc -z 127.0.0.1 $PORT >/dev/null 2>&1; then echo "port $PORT on this Mac is in use; cannot start the test sshd"; exit 2; fi
VMKEY=$("$AISB" key 2>/dev/null) || { echo "the sandbox is not set up (aisandbox up)"; exit 2; }
others_before=$("$AISB" tunnel ls | grep -v aisbtest- | awk 'NF >= 6 { print $1, $NF }')

mkdir -p "$TMP/bin"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/client"
{
	printf 'restrict,port-forwarding %s\n' "$(cat "$TMP/client.pub")"
	printf 'restrict,command="echo tunnel-test-ok" %s\n' "$VMKEY"
} > "$TMP/authorized_keys"
cat > "$TMP/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $TMP/hostkey
AuthorizedKeysFile $TMP/authorized_keys
PidFile $TMP/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
cat > "$TMP/ssh_config" <<EOF
Host i-0aisbtest
  HostName 127.0.0.1
  Port $PORT
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $TMP/known_hosts
  StrictHostKeyChecking accept-new
  ProxyCommand sh -c 'if [ "\$AISB_TEST_PROFILE" = ok ]; then exec nc 127.0.0.1 $PORT; else echo "fake-proxy: profile [\$AISB_TEST_PROFILE] is not authorized" >&2; exit 1; fi'
EOF
cat > "$TMP/bin/ssh" <<EOF
#!/bin/sh
case " \$* " in *"@i-0aisbtest "*) exec $REAL_SSH -F "$TMP/ssh_config" "\$@" ;; esac
exec $REAL_SSH "\$@"
EOF
chmod +x "$TMP/bin/ssh"
/usr/sbin/sshd -f "$TMP/sshd_config" -D -e 2>"$TMP/sshd.log" &
SSHD=$!
sleep 1
kill -0 "$SSHD" 2>/dev/null || { echo "the test sshd did not start:"; cat "$TMP/sshd.log"; exit 2; }

# The CLI with the stub ssh, and WITHOUT the variable in its environment: the
# tunnel has to bring its own.
a() { env -u AISB_TEST_PROFILE PATH="$TMP/bin:$PATH" "$AISB" "$@" 2>&1; }
TARGET="$USER@i-0aisbtest"
vm_login() { agent ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$1" 2>&1 | tr -d '\r' | tail -1; }

section "without the variable the Mac's login is refused, and the reason is shown"
out=$(a tunnel add aisbtest-noenv "$TARGET" -i "$TMP/client" --remote-port $PORT); rc=$?
is "tunnel add fails" "$rc" "1"
like "with the proxy's own message" "$out" "fake-proxy: profile \[\] is not authorized"
a tunnel rm aisbtest-noenv >/dev/null

section "with -i and --env the tunnel opens and the agent can log in"
out=$(a tunnel add aisbtest-env "$TARGET" -i "$TMP/client" --env AISB_TEST_PROFILE=ok --remote-port $PORT --note "throwaway test target"); rc=$?
is "tunnel add succeeds" "$rc" "0"
like "reported as up" "$out" "up +aisbtest-env:"
is "the agent's login through it" "$(vm_login aisbtest-env)" "tunnel-test-ok"
like "sandbox-tunnels shows it open, with the note" "$(agent sandbox-tunnels | tr -d '\r')" "aisbtest-env +open .*throwaway test target"
like "the agent instructions list it" "$(agent cat /etc/claude-code/CLAUDE.md)" "aisbtest-env.*throwaway test target"
leaks=$(agent sh -c 'cat /etc/claude-code/CLAUDE.md /etc/aisandbox/tunnels /etc/ssh/ssh_config.d/aisandbox.conf' | grep -c -E "i-0aisbtest|AISB_TEST_PROFILE|$TMP")
is "target, variable and key path did not reach the VM" "$leaks" "0"

section "closing it cuts the agent off"
a tunnel down aisbtest-env >/dev/null
unlike "the agent's login now fails" "$(vm_login aisbtest-env)" "tunnel-test-ok"
like "sandbox-tunnels shows it closed" "$(agent sandbox-tunnels | tr -d '\r')" "aisbtest-env +closed"

section "reopening uses the stored key and variable"
out=$(a tunnel up aisbtest-env); rc=$?
is "tunnel up succeeds with nothing in the environment" "$rc" "0"
is "the agent's login works again" "$(vm_login aisbtest-env)" "tunnel-test-ok"

section "removing it"
is "tunnel rm" "$(a tunnel rm aisbtest-env >/dev/null; echo $?)" "0"
is "gone from the agent's ssh config" "$(agent grep -c 'Host aisbtest-env' /etc/ssh/ssh_config.d/aisandbox.conf | tr -d '\r')" "0"
is "your own tunnels are as they were" "$("$AISB" tunnel ls | grep -v aisbtest- | awk 'NF >= 6 { print $1, $NF }')" "$others_before"

finish
