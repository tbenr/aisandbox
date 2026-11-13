#!/bin/bash
#
# Tests that need the VM stopped, restarted or deliberately un-hardened:
# the fail-closed behaviour of `up`, and what is in place straight from boot.
#
# THIS SUITE IS DISRUPTIVE. It stops and restarts the VM several times, which
# ends every agent session in it, and it closes your tunnels. For a moment it
# removes the firewall and gives the agent user sudo back, to check that `up`
# undoes that. It ends with a real `aisandbox up`, which reopens your
# autostart tunnels with your credentials.
#
# It therefore only runs when asked twice:
#   AISB_TEST_DISRUPTIVE=yes test/disruptive.sh

. "$(dirname "$0")/lib.sh"
need_orb
if [ "${AISB_TEST_DISRUPTIVE:-}" != yes ]; then
	sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
fi
"$REAL_ORB" list -q 2>/dev/null | grep -qx -- "$MACHINE" || { echo "no OrbStack machine named $MACHINE"; exit 2; }

make_tmp
AGENT=$("$REAL_ORB" config show | awk -F': ' -v k="machine.$MACHINE.username" '$1 == k { print $2 }')
AGENT=${AGENT:-$USER}
vm_state() { "$REAL_ORB" list | awk -v m="$MACHINE" '$1 == m { print $2 }'; }
cfg() { "$REAL_ORB" config show | awk -F': ' -v k="$1" '$1 == k { print $2 }'; }
wait_vm() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do agent true 2>/dev/null && return 0; sleep 1; done; return 1; }

SHARE=
cleanup() {
	# Whatever happened: settings right, the test share gone, and the sandbox
	# brought up properly.
	"$REAL_ORB" config set "machine.$MACHINE.forward_ssh_agent" false >/dev/null 2>&1
	if [ -n "$SHARE" ]; then
		"$REAL_ORB" config remove "machine.$MACHINE.mounts" "$SHARE" >/dev/null 2>&1
		"$REAL_ORB" config remove "machine.$MACHINE.mounts" "$SHARE:$SHARE" >/dev/null 2>&1
	fi
	"$AISB" up >/dev/null 2>&1
	rm -rf "$TMP"
}
trap cleanup EXIT

"$AISB" up >/dev/null 2>&1 || { echo "the sandbox does not come up cleanly to begin with; fix that first (aisandbox up)"; trap - EXIT; rm -rf "$TMP"; exit 2; }

section "an OrbStack isolation setting that drifted is corrected, with a restart"
"$REAL_ORB" config set "machine.$MACHINE.forward_ssh_agent" true >/dev/null 2>&1
out=$("$AISB" up 2>&1); rc=$?
is "up succeeds" "$rc" "0"
like "says what it corrected" "$out" "forward_ssh_agent true -> false"
like "and that it restarts the VM for it" "$out" "Restarting $MACHINE to apply the corrected isolation settings"
is "the setting is back" "$(cfg "machine.$MACHINE.forward_ssh_agent")" "false"

section "a shared folder still at /mnt/mac is moved to its Mac path, with one restart"
mkdir -p "$TMP/share" && touch "$TMP/share/MARKER"
SHARE=$(cd "$TMP/share" && pwd -P)
"$REAL_ORB" config add "machine.$MACHINE.mounts" "$SHARE" >/dev/null 2>&1
out=$("$AISB" up 2>&1); rc=$?
is "up succeeds" "$rc" "0"
like "says the folder will be at its Mac path" "$out" "shared folder $SHARE: will be mounted at its Mac path"
like "and restarts the VM once for it" "$out" "Restarting $MACHINE once, to mount the shared folders at their Mac paths"
like "OrbStack's entry is now SOURCE:SOURCE" "$(cfg "machine.$MACHINE.mounts")" "(^|,)$SHARE:$SHARE(,|\$)"
is "in the VM it is OrbStack's mount, at the Mac path" "$(root findmnt -n -o FSTYPE -M "$SHARE" | tr -d '\r')" "virtiofs"
is "showing the folder" "$(agent ls "$SHARE" | tr -d '\r')" "MARKER"
is "nothing of it is left at /mnt/mac" "$(root sh -c "ls -A '/mnt/mac$SHARE' 2>/dev/null | wc -l" | tr -d ' \r')" "0"
out=$("$AISB" up 2>&1); rc=$?
unlike "a second up has nothing to move and does not restart" "$out" "Restarting"
"$REAL_ORB" config remove "machine.$MACHINE.mounts" "$SHARE:$SHARE" >/dev/null 2>&1
SHARE=

section "a VM that still has the mount service of an earlier version"
root sh -c 'printf "[Unit]\nDescription=old mount service\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/aisandbox-paths mount\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/aisandbox-paths.service \
	&& printf "#!/bin/sh\nexit 0\n" > /usr/local/sbin/aisandbox-paths && chmod 755 /usr/local/sbin/aisandbox-paths \
	&& touch /etc/aisandbox/pathmounts && systemctl daemon-reload && systemctl enable aisandbox-paths.service >/dev/null 2>&1'
is "precondition: the old service is enabled" "$(root systemctl is-enabled aisandbox-paths.service 2>/dev/null | tr -d '\r')" "enabled"
out=$("$AISB" up 2>&1); rc=$?
is "up succeeds" "$rc" "0"
like "says it removed the service" "$out" "removed the mount service of an earlier version"
like "and restarts the VM once, since the service may have run at this boot" "$out" "Restarting $MACHINE once"
is "service, script and records are gone" "$(root sh -c 'ls /etc/systemd/system/aisandbox-paths.service /usr/local/sbin/aisandbox-paths /etc/aisandbox/pathmounts 2>/dev/null | wc -l' | tr -d ' \r')" "0"
out=$("$AISB" up 2>&1)
unlike "a second up has nothing left to remove and does not restart" "$out" "Restarting|removed the mount service"

section "a VM found without its hardening is hardened and restarted once"
root sh -c "echo '$AGENT ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/orbstack && chmod 440 /etc/sudoers.d/orbstack && nft delete table inet aisandbox"
is "precondition: the agent can sudo again" "$(agent sudo -n true >/dev/null 2>&1; echo $?)" "0"
out=$("$AISB" up 2>&1); rc=$?
is "up succeeds" "$rc" "0"
like "it restarts the VM once" "$out" "Restarting $MACHINE once"
is "the agent cannot sudo" "$(agent sudo -n true >/dev/null 2>&1; echo $?)" "1"
is "the firewall is loaded" "$(root nft list table inet aisandbox >/dev/null 2>&1; echo $?)" "0"

section "if the hardening cannot be applied, the VM is stopped"
mkdir -p "$TMP/broken/vm"
cp "$AISB" "$TMP/broken/"
cp "$REPO/vm/provision.sh" "$REPO/vm/sharecheck.sh" "$TMP/broken/vm/"
{ cat "$REPO/vm/nftables.conf"; echo "this is not valid nft syntax {"; } > "$TMP/broken/vm/nftables.conf"
out=$("$TMP/broken/aisandbox" up 2>&1); rc=$?
is "up fails" "$rc" "1"
like "says the VM was stopped" "$out" "has been stopped so that it does not keep running unhardened"
is "the VM is stopped" "$(vm_state)" "stopped"

section "if the VM starts but never accepts commands, it is stopped"
mkdir -p "$TMP/notready"
cat > "$TMP/notready/orb" <<EOF
#!/bin/sh
[ "\$*" = "-m $MACHINE true" ] && exit 1
exec "$REAL_ORB" "\$@"
EOF
chmod +x "$TMP/notready/orb"
out=$(env PATH="$TMP/notready:$PATH" "$AISB" up 2>&1); rc=$?
is "up fails" "$rc" "1"
like "says why" "$out" "does not accept commands"
is "the VM is stopped" "$(vm_state)" "stopped"

section "started without the tool, the VM is hardened from boot"
"$REAL_ORB" start "$MACHINE" >/dev/null 2>&1
wait_vm || fail "the VM did not come up"
is "the firewall is loaded" "$(root nft list table inet aisandbox >/dev/null 2>&1; echo $?)" "0"
is "the agent cannot sudo" "$(agent sudo -n true >/dev/null 2>&1; echo $?)" "1"
# OrbStack mounts the shared folders before anything in the VM runs, so they
# are there at once, with no service of ours involved.
shares=$(cfg "machine.$MACHINE.mounts" | tr ',' '\n')
if [ -z "$shares" ]; then printf '  skip  no shared folders configured\n'; fi
for entry in $shares; do
	src=${entry%%:*}
	case "$entry" in *:*) at=${entry#*:} ;; *) at=/mnt/mac$src ;; esac
	is "$src is mounted at $at" "$(root findmnt -n -o FSTYPE -M "$at" | tr -d '\r')" "virtiofs"
done

section "down and up"
is "down stops it" "$("$AISB" down >/dev/null 2>&1; echo $?) $(vm_state)" "0 stopped"
out=$("$AISB" up 2>&1); rc=$?
is "up brings it back" "$rc $(vm_state)" "0 running"
is "doctor passes" "$("$AISB" doctor >/dev/null 2>&1; echo $?)" "0"
trap 'rm -rf "$TMP"' EXIT

finish
