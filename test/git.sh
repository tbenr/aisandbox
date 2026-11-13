#!/bin/bash
#
# Tests of how git behaves for an agent in the VM: unsigned commits, and the
# guards that keep the VM from pruning worktree metadata that belongs to the
# Mac.
#
# Needs the VM running. Everything happens in throwaway repositories under
# /tmp in the VM, as the agent user, in a login shell (which is what an agent
# session gets). Your shared repositories are only read: one `git config`
# lookup each, to see that the VM-only setting really overrides theirs.
#
# `git worktree prune` is deliberately run here, and ONLY in a throwaway
# repository: if the guard were missing, in a real one it would do the damage
# the guard exists to prevent.

. "$(dirname "$0")/lib.sh"
need_vm

SHARES=$("$REAL_ORB" config show 2>/dev/null | awk -F': ' -v k="machine.$MACHINE.mounts" '$1 == k { print $2 }' | tr ',' '\n' | sed 's/:.*//')

# The VM-side half is a file of its own (test/git-vm.sh), piped into a login
# shell of the agent user.
RES=$("$REAL_ORB" -m "$MACHINE" bash -l -s -- $SHARES < "$(dirname "$0")/git-vm.sh" 2>&1 | tr -d '\r')
get() { printf '%s\n' "$RES" | sed -n "s/^$1=//p" | head -1; }

section "git in the VM"
is "git is the guarded wrapper" "$(get git_path)" "/usr/local/bin/git"
is "signing is off in a login shell" "$(get env_setting)" "false"
is "gc never prunes worktrees (system setting)" "$(get system_gc)" "never"

section "committing in a repository that demands signatures"
is "the commit succeeds" "$(get commit_rc)" "0"
is "it is unsigned" "$(get signature)" "N"
is "it has an author" "$(get author_set)" "yes"
if [ "$(get commit_without_setting_rc)" != 0 ]; then pass "without the VM setting the same commit fails, so the setting is what does it"
else fail "the commit also succeeded without the VM setting; the test proves nothing"; fi

section "worktree metadata that looks missing is not pruned"
is "the test worktree does look prunable" "$(get prunable)" "1"
is "git worktree prune" "$(get prune)" "1 kept"
is "git -C <dir> worktree prune" "$(get prune_C)" "1 kept"
is "git --git-dir=… --work-tree=… worktree prune" "$(get prune_gitdir)" "1 kept"
is "git -c … --no-pager worktree prune --expire now" "$(get prune_opts)" "1 kept"
like "it says why" "$(get prune_message)" "disabled in this sandbox"
is "git gc" "$(get gc)" "0 kept"
is "git gc --prune=now" "$(get gc_prune_now)" "0 kept"
is "git worktree list still works" "$(get worktree_list)" "0"
is "other commands pass through" "$(get log)" "0"

section "the shared repositories (read only)"
found=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	found=1
	like "${line%% local=*}: unsigned in the VM whatever the repository says" "$line" "effective=false$"
done <<EOF
$(printf '%s\n' "$RES" | sed -n 's/^shared=//p')
EOF
[ "$found" = 1 ] || printf '  skip  no shared folder is a git repository\n'

if printf '%s\n' "$RES" | grep -q "^unexpected temp dir"; then fail "the VM-side script did not run: $RES"; fi
finish
