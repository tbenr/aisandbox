#!/bin/bash
#
# Runs as root INSIDE the sandbox VM. It is piped in from the Mac by
# `aisandbox` (orb -m <machine> -u root bash -s); nothing in the VM needs to
# be able to become root for this to work, which is the point.
#
# Idempotent: safe to run on every `aisandbox up`.
#
# Order matters: the steps that take things away from the agent (root, then
# private-network access) come first, so a failure further down never leaves
# them undone. The caller stops the VM if this script fails at all.
#
# Inputs (environment):
#   AGENT_USER      user the agents run as (loses sudo)
#   TUNNEL_PUBKEY   Mac-side public key allowed to open tunnels
#   SSHD_PORT       loopback port of the tunnel sshd
#   NFT_RULES       path of the firewall rules file already copied into the VM
#   GIT_AUTHOR_NAME_DEFAULT, GIT_AUTHOR_EMAIL_DEFAULT
#                   optional: git author identity to set as the VM's default

set -euo pipefail

: "${AGENT_USER:?}" "${TUNNEL_PUBKEY:?}" "${SSHD_PORT:?}" "${NFT_RULES:?}"

TUNNEL_USER=aisb-tunnel
REBOOT_FLAG=/run/aisandbox-reboot-needed    # /run is emptied by a reboot
step() { printf '  - %s\n' "$*"; }
die() { printf 'provision: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
id "$AGENT_USER" >/dev/null 2>&1 || die "no such user in the VM: $AGENT_USER"
[ "$(id -u "$AGENT_USER")" != 0 ] || die "the agent user must not be root"

as_agent() { runuser -u "$AGENT_USER" -- "$@"; }

apt_install() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' && return 0
	step "installing $1"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends "$1" >/dev/null
}

# Was the VM running without its hardening until now? Then processes and
# connections started in that state may still be around (a root shell, a
# connection to the LAN), and only a reboot gets rid of them for certain.
reboot_why=""
if ! nft list table inet aisandbox >/dev/null 2>&1; then
	reboot_why="the firewall was not loaded"
fi
if as_agent sudo -n true 2>/dev/null; then
	reboot_why="${reboot_why:+$reboot_why, }$AGENT_USER could sudo"
fi

# --- 1. take root away from the agent user -------------------------------------
changed=""
for f in /etc/sudoers.d/*; do
	[ -f "$f" ] || continue
	case "$f" in */README) continue ;; esac
	if grep -Eq "^[[:space:]]*$AGENT_USER[[:space:]]" "$f"; then
		rm -f "$f"
		changed="$changed ${f##*/}"
	fi
done
for g in sudo adm admin wheel; do
	if id -nG "$AGENT_USER" | tr ' ' '\n' | grep -qx "$g"; then
		gpasswd -d "$AGENT_USER" "$g" >/dev/null
		changed="$changed group:$g"
	fi
done
passwd -l root >/dev/null
passwd -l "$AGENT_USER" >/dev/null
if as_agent sudo -n true 2>/dev/null; then
	die "$AGENT_USER can still sudo without a password"
fi
step "agent user $AGENT_USER has no sudo${changed:+ (removed:$changed)}"

# --- 2. firewall -----------------------------------------------------------------
# On the very first run the nftables package has to be downloaded before the
# rules can exist; that is the only time anything happens ahead of them.
apt_install nftables
nft -c -f "$NFT_RULES" || die "firewall rules do not validate"
install -m 0644 -o root -g root "$NFT_RULES" /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables.service >/dev/null 2>&1
nft list table inet aisandbox >/dev/null || die "firewall table missing after load"
systemctl is-enabled nftables.service >/dev/null 2>&1 || die "the firewall is not enabled at boot"
dns=$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf | tr '\n' ' ')
case "$dns" in
	"0.250.250.200 ") ;;
	*) printf '  ! resolv.conf nameserver is "%s", firewall allows DNS only to 0.250.250.200 (edit vm/nftables.conf)\n' "$dns" ;;
esac
step "firewall loaded and enabled at boot"

# --- 3. tunnel sshd -----------------------------------------------------------------
# The configuration is written BEFORE openssh-server is installed, so sshd
# never comes up on its default 0.0.0.0:22, not even for a moment.
install -d -m 0755 /etc/ssh/sshd_config.d /etc/ssh/authorized_keys.d
cat > /etc/ssh/sshd_config.d/00-aisandbox.conf <<EOF
# Managed by aisandbox. Loopback-only sshd whose single purpose is to let the
# Mac push reverse tunnels (ssh -R) into this VM.
Port $SSHD_PORT
AddressFamily inet
ListenAddress 127.0.0.1

AllowUsers $TUNNEL_USER
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u

AllowTcpForwarding remote
GatewayPorts no
AllowAgentForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
PermitTTY no
PermitUserRC no
ForceCommand /bin/false
EOF
chmod 0644 /etc/ssh/sshd_config.d/00-aisandbox.conf
apt_install openssh-server

if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
	step "creating user $TUNNEL_USER"
	useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$TUNNEL_USER"
fi
# '*' = no valid password, but (unlike '!') not "locked", so key login works.
usermod -p '*' "$TUNNEL_USER"
printf 'restrict,port-forwarding %s\n' "$TUNNEL_PUBKEY" > "/etc/ssh/authorized_keys.d/$TUNNEL_USER"
chown root:root "/etc/ssh/authorized_keys.d/$TUNNEL_USER"
chmod 0644 "/etc/ssh/authorized_keys.d/$TUNNEL_USER"

# Ubuntu ships socket activation (ssh.socket); a plain service reads our
# Port/ListenAddress directly, with no generator in between.
mkdir -p /run/sshd
/usr/sbin/sshd -t || die "sshd config does not validate"
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1
systemctl restart ssh.service
for _ in 1 2 3 4 5 6 7 8 9 10; do
	ss -Hltn "sport = :$SSHD_PORT" | grep -q . && break
	sleep 0.3
done
listeners=$(ss -Hltnp | awk '/"sshd"/ {print $4}' | sort -u | tr '\n' ' ')
[ "$listeners" = "127.0.0.1:$SSHD_PORT " ] || die "sshd is listening on '$listeners', expected only 127.0.0.1:$SSHD_PORT"
step "tunnel sshd listening on $listeners"

# --- 4. the key agents use to log in to targets ---------------------------------------
# Done AS the agent user, never as root: the agent owns its home directory and
# could put a symlink where ~/.ssh should be. A root-run mkdir/chmod would
# follow it and change permissions somewhere else in the system.
as_agent sh -c '
	umask 077
	cd || exit 1
	mkdir -p .ssh || exit 1
	[ -f .ssh/id_ed25519 ] && exit 0
	ssh-keygen -q -t ed25519 -N "" -C "aisandbox-agent@$(hostname)" -f .ssh/id_ed25519 && echo "  - generated the agent key ~/.ssh/id_ed25519"
' || printf '  ! could not create the agent key as %s (check ~/.ssh in the VM); tunnels will not authenticate\n' "$AGENT_USER"
# Not fatal on purpose: this step depends on files the agent controls, and it
# is not part of the hardening, which is complete at this point.

# The per-tunnel client config is written by `aisandbox` after this script.
install -d -m 0755 /etc/ssh/ssh_config.d
[ -f /etc/ssh/ssh_config.d/aisandbox.conf ] || : > /etc/ssh/ssh_config.d/aisandbox.conf
chmod 0644 /etc/ssh/ssh_config.d/aisandbox.conf

# --- 5. git for the agents ----------------------------------------------------------------
apt_install git

# The shared repositories carry commit.gpgsign=true in their own .git/config,
# and the VM has no signing key (on purpose), so a plain `git commit` here
# would fail. These variables are git configuration passed through the
# environment; they rank above a repository's config, so they switch signing
# off INSIDE THE VM without touching the shared .git/config. On the Mac the
# same repositories keep signing.
# /etc/profile.d is read by login shells, which is how OrbStack's SSH (and so
# Claude desktop) starts everything in this VM.
cat > /etc/profile.d/aisandbox-git.sh <<'EOF'
# Managed by aisandbox. Commits made in this VM are unsigned: the signing key
# stays on the Mac. See vm/provision.sh.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=tag.gpgsign
export GIT_CONFIG_VALUE_1=false
# Worktrees that live on the Mac outside the shared folders look missing from
# here. Never let an automatic `git gc` prune their metadata.
export GIT_CONFIG_KEY_2=gc.worktreePruneExpire
export GIT_CONFIG_VALUE_2=never
EOF
chmod 0644 /etc/profile.d/aisandbox-git.sh

# The same protection for processes that did not start from a login shell.
git config --system gc.worktreePruneExpire never

# `git gc` is covered by the setting above; an explicit `git worktree prune`
# is not, so this wrapper refuses that one subcommand. /usr/local/bin comes
# before /usr/bin in PATH. It guards against an agent tidying up entries that
# `git worktree list` marks "prunable"; it is not a security boundary.
cat > /usr/local/bin/git <<'EOF'
#!/bin/bash
# Managed by aisandbox. Passes everything to the real git, except
# `git worktree prune`, which must not run in this VM.
args=("$@")
i=0
# Skip git's own leading options to find the subcommand.
while [ $i -lt ${#args[@]} ]; do
	case "${args[$i]}" in
		-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) i=$((i + 2)) ;;
		-*) i=$((i + 1)) ;;
		*) break ;;
	esac
done
if [ "${args[$i]:-}" = worktree ] && [ "${args[$((i + 1))]:-}" = prune ]; then
	cat >&2 <<'MSG'
git worktree prune is disabled in this sandbox.
Worktrees that live on the Mac outside the shared folders look missing from
here ("prunable"), but they exist. Pruning would delete their metadata on the
Mac. If pruning is really needed, ask the user to run it on the Mac.
MSG
	exit 1
fi
exec /usr/bin/git "$@"
EOF
chmod 0755 /usr/local/bin/git

# Author identity, copied from the Mac's git config, as a system-wide default.
if [ -n "${GIT_AUTHOR_NAME_DEFAULT:-}" ] && [ -n "${GIT_AUTHOR_EMAIL_DEFAULT:-}" ]; then
	git config --system user.name "$GIT_AUTHOR_NAME_DEFAULT"
	git config --system user.email "$GIT_AUTHOR_EMAIL_DEFAULT"
	step "git ready: unsigned commits, authored as $GIT_AUTHOR_NAME_DEFAULT"
else
	step "git ready: unsigned commits (no author identity found on the Mac to copy)"
fi

# --- 6. how agents find out about the tunnels -----------------------------------------------
# `sandbox-tunnels` lists the tunnels with their live state. The list itself
# (/etc/aisandbox/tunnels: name|port|user|note) and the instruction file
# /etc/claude-code/CLAUDE.md are written by `aisandbox` after this script.
install -d -m 0755 /etc/aisandbox /etc/claude-code
[ -f /etc/aisandbox/tunnels ] || : > /etc/aisandbox/tunnels
cat > /usr/local/bin/sandbox-tunnels <<'EOF'
#!/bin/bash
# Managed by aisandbox. Lists the SSH tunnels available in this sandbox VM and
# whether each one is open right now.
data=/etc/aisandbox/tunnels
if [ ! -s "$data" ]; then
	echo "No tunnels are registered for this sandbox."
	echo "The user adds them on the Mac with: aisandbox tunnel add <name> <ssh-target>"
	exit 0
fi
width=4
while IFS='|' read -r name _; do [ ${#name} -gt $width ] && width=${#name}; done < "$data"
printf "%-${width}s  %-6s  %-12s  %s\n" NAME STATE LOGIN DESCRIPTION
closed=0
while IFS='|' read -r name port user note; do
	[ -n "$name" ] || continue
	# An SSH server answering through the port proves the whole path is open.
	if [ "$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && head -c 4 <&3" 2>/dev/null)" = "SSH-" ]; then
		state=open
	else
		state=closed
		closed=1
	fi
	printf "%-${width}s  %-6s  %-12s  %s\n" "$name" "$state" "$user" "${note:--}"
done < "$data"
echo
echo "Use an open tunnel with: ssh <name>   (also scp and rsync)"
if [ "$closed" = 1 ]; then
	echo "A closed tunnel can only be opened by the user, on the Mac: aisandbox tunnel up <name>"
fi
EOF
chmod 0755 /usr/local/bin/sandbox-tunnels
step "sandbox-tunnels command installed"

# --- 7. the mount service of earlier versions ---------------------------------------------------
# Shared folders used to be bind-mounted at their Mac paths by a script of
# ours, with a service that redid it at every boot. OrbStack mounts them there
# itself now (see share_list in aisandbox). On a VM that still has that
# service it must go, and not only for tidiness: at boot it finds OrbStack's
# mount at the path, does not recognise it, unmounts it, and binds the old,
# now empty /mnt/mac directory in its place. It may have done so at this very
# boot, which only a restart undoes, so one is asked for.
if [ -e /etc/systemd/system/aisandbox-paths.service ] || [ -e /usr/local/sbin/aisandbox-paths ]; then
	systemctl disable aisandbox-paths.service >/dev/null 2>&1 || true
	rm -f /etc/systemd/system/aisandbox-paths.service /usr/local/sbin/aisandbox-paths
	( cd /etc/aisandbox && rm -f paths.sh pathmounts pathdirs pathshares pathrefused pathlinks agent-user )
	systemctl daemon-reload
	step "removed the mount service of an earlier version"
	reboot_why="${reboot_why:+$reboot_why, }the mount service of an earlier version was still installed"
fi

# --- 8. does the VM need a reboot? --------------------------------------------------------
if [ -n "$reboot_why" ]; then
	: > "$REBOOT_FLAG"
	step "reboot needed ($reboot_why before this run)"
fi

echo "provision: ok"
