#!/bin/bash
#
# Tests of vm/sharecheck.sh: may a shared folder be mounted at a given path
# in the VM?
#
# Needs the VM running. The script under test only looks; this suite sets up
# the situations for it on disposable paths in the VM (/aisbtest as root,
# /tmp/aisb-atk as the agent) and removes them again at the end, also after a
# failure. Your shared folders are not involved.

. "$(dirname "$0")/lib.sh"
need_vm

AGENT=$(agent id -un | tr -d '\r')

# verdict <path>: "safe" or "unsafe"; why <path>: the reason given.
ask() { "$REAL_ORB" -m "$MACHINE" -u root env AGENT_USER="$AGENT" bash -s -- "$@" < "$REPO/vm/sharecheck.sh" 2>&1 | tr -d '\r'; }
verdict() { ask "$1" | cut -f1; }
why() { ask "$1" | cut -f3; }
kind() { root sh -c 'if [ -L "$1" ]; then echo link; elif mountpoint -q "$1" 2>/dev/null; then echo mount; elif [ -d "$1" ]; then echo dir; elif [ -e "$1" ]; then echo file; else echo absent; fi' sh "$1"; }

cleanup() {
	root bash -c '
		findmnt -rn -o TARGET | grep -E "^/aisbtest(/|\$)" | sort -r | while read -r m; do umount "$m" 2>/dev/null || umount -l "$m"; done
		if findmnt -rn -o TARGET | grep -qE "^/aisbtest(/|\$)"; then echo "test mounts could not be removed; nothing was deleted" >&2; exit 1; fi
		if [ -e /aisbtest ]; then find /aisbtest -xdev -depth -delete; fi'
	agent sh -c 'if [ -d /tmp/aisb-atk ]; then find /tmp/aisb-atk -depth -delete; fi'
}
trap cleanup EXIT
cleanup    # leftovers of an interrupted run

root bash -c "mkdir -p /aisbtest/plain /aisbtest/empty /aisbtest/full /aisbtest/owned /aisbtest/mounted /aisbtest/src \
	&& touch /aisbtest/full/something && chown $AGENT: /aisbtest/owned \
	&& ln -s /etc /aisbtest/dirlink && ln -s /etc /aisbtest/plain/target-is-link \
	&& mount --bind /aisbtest/src /aisbtest/mounted"
agent sh -c 'mkdir -p /tmp/aisb-atk/a'

section "paths nobody but root can reach are safe"
is "nothing there yet, parents exist" "$(verdict /aisbtest/plain/repo)" "safe"
is "parents do not exist yet either" "$(verdict /aisbtest/not/there/yet/repo)" "safe"
is "an empty directory only root can change" "$(verdict /aisbtest/empty)" "safe"
is "already a mount point" "$(verdict /aisbtest/mounted)" "safe"
is "a trailing slash makes no difference" "$(ask /aisbtest/plain/repo/ | tr '\t' '|')" "safe|/aisbtest/plain/repo"

section "paths the agent could redirect are not"
is "under a directory the agent owns" "$(verdict /tmp/aisb-atk/a/b/repo)" "unsafe"
like "names the directory that is the problem" "$(why /tmp/aisb-atk/a/b/repo)" "^/tmp can be changed by a non-root user"
is "under the agent's home directory" "$(verdict "/home/$AGENT/projects/repo")" "unsafe"
is "through a symlink on the way" "$(verdict /aisbtest/dirlink/repo)" "unsafe"
like "says it is a symlink" "$(why /aisbtest/dirlink/repo)" "/aisbtest/dirlink is a symlink"
is "the path itself is a symlink" "$(verdict /aisbtest/plain/target-is-link)" "unsafe"
is "the path is a directory the agent owns" "$(verdict /aisbtest/owned)" "unsafe"

section "paths where something is in the way are not"
is "a directory with content" "$(verdict /aisbtest/full)" "unsafe"
like "says so" "$(why /aisbtest/full)" "already exists in the VM and is not empty"
is "a system directory" "$(verdict /etc)" "unsafe"
is "the root directory" "$(verdict /)" "unsafe"
is "a relative path" "$(verdict relative/path)" "unsafe"

section "several paths at once, answered in order"
is "one line each" "$(ask /aisbtest/plain/repo /tmp/aisb-atk/a/b/repo /aisbtest/empty | cut -f1 | tr '\n' ' ')" "safe unsafe safe "

section "the check only looks"
is "it created nothing at a safe path" "$(kind /aisbtest/plain/repo) $(kind /aisbtest/not)" "absent absent"
is "nor at an unsafe one" "$(kind /tmp/aisb-atk/a/b)" "absent"

finish
