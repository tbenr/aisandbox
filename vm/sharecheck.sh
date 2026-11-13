#!/bin/bash
#
# Answers one question for each path given as an argument: may a shared
# folder be mounted at this path in the VM?
#
# Runs as root inside the VM, piped in from the Mac by `aisandbox` before it
# asks OrbStack to mount a shared folder at the path it has on the Mac
# (/Users/you/repo). Prints one line per path:
#     safe<TAB>path
#     unsafe<TAB>path<TAB>why
#
# Why this is asked at all: OrbStack sets the mount up when the VM starts, at
# a path inside the VM's own file system, and that file system persists. If
# the agent could change a directory on the way to that path (a Mac path
# under /tmp, say), it could leave a symlink there and have the next start
# mount the folder somewhere else. So a path is safe only if nobody but root
# can change any directory above it, and nothing is in the way at the path
# itself. Because such directories cannot be changed by the agent later
# either, asking once, before the share is set up, is enough.
#
# Environment: AGENT_USER, the user agents run as.

set -euo pipefail
: "${AGENT_USER:?}"
[ "$(id -u)" = 0 ] || { echo "sharecheck: must run as root" >&2; exit 1; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo "sharecheck: no such user: $AGENT_USER" >&2; exit 1; }

WHY=""

# True if directory $1 can be changed by root only: a real directory, not a
# symlink, owned by root, not writable by group or others, and (this covers
# ACLs too) not writable by the agent user in practice.
root_only_dir() {
	local perm
	[ -d "$1" ] && [ ! -L "$1" ] || return 1
	[ "$(stat -c %u "$1")" = 0 ] || return 1
	perm=$(stat -c %a "$1")
	[ $(( 0$perm & 022 )) -eq 0 ] || return 1
	! runuser -u "$AGENT_USER" -- test -w "$1"
}

check() {
	local target=$1 cur="" part parent
	local -a parts
	WHY=""
	case "$target" in
		/) WHY="the root directory cannot be a mount point for a share"; return 1 ;;
		/*) ;;
		*) WHY="not an absolute path"; return 1 ;;
	esac

	# Every directory above the path, as far as it exists.
	root_only_dir / || { WHY="/ can be changed by a non-root user"; return 1; }
	parent=$(dirname "$target")
	IFS=/ read -r -a parts <<< "${parent#/}"
	for part in "${parts[@]}"; do
		[ -n "$part" ] || continue
		case "$part" in .|..) WHY="not a plain absolute path"; return 1 ;; esac
		cur="$cur/$part"
		if [ ! -e "$cur" ] && [ ! -L "$cur" ]; then
			break       # from here on it does not exist: root will create it, below a directory only root can change
		fi
		if ! root_only_dir "$cur"; then
			if [ -L "$cur" ]; then WHY="$cur is a symlink in the VM"
			elif [ ! -d "$cur" ]; then WHY="$cur is not a directory in the VM"
			else WHY="$cur can be changed by a non-root user in the VM, so the mount could be redirected"; fi
			return 1
		fi
	done

	# The path itself: free, an empty directory only root can change, or
	# already a mount point (putting a mount there took root).
	if [ -L "$target" ]; then WHY="$target is a symlink in the VM"; return 1; fi
	if [ -e "$target" ] && ! mountpoint -q "$target"; then
		root_only_dir "$target" || { WHY="$target exists in the VM and is not a directory that only root can change"; return 1; }
		[ -z "$(ls -A "$target")" ] || { WHY="$target already exists in the VM and is not empty"; return 1; }
	fi
	return 0
}

for path in "$@"; do
	while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
	if check "$path"; then printf 'safe\t%s\n' "$path"
	else printf 'unsafe\t%s\t%s\n' "$path" "$WHY"; fi
done
