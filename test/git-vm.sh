#!/bin/bash
#
# The VM-side half of test/git.sh: runs as the agent user in a login shell and
# prints key=value lines for the Mac-side half to check. Arguments: the Mac
# paths of the shared folders. Works in a throwaway directory under /tmp.

T=$(mktemp -d)
case "$T" in /tmp/*) ;; *) echo "unexpected temp dir: $T"; exit 1 ;; esac
cd "$T" || exit 1

echo "git_path=$(command -v git)"
echo "env_setting=$(git config --get commit.gpgsign)"
echo "system_gc=$(git config --system --get gc.worktreePruneExpire)"

# A repository that demands signed commits, like the shared ones do.
git init -q signed && cd signed && git config commit.gpgsign true
echo x > f && git add f
git commit -q -m test >/dev/null 2>&1; echo "commit_rc=$?"
echo "signature=$(git log -1 --format=%G? 2>/dev/null)"
echo "author_set=$([ -n "$(git log -1 --format=%an 2>/dev/null)" ] && echo yes || echo no)"
env -u GIT_CONFIG_COUNT git commit -q --allow-empty -m again >/dev/null 2>&1; echo "commit_without_setting_rc=$?"

# A repository with a worktree that looks missing and old, the way a worktree
# on the Mac outside the shared folders looks from here.
cd "$T" && git init -q repo && cd repo && git commit -q --allow-empty -m init && git worktree add -q ../wt -b wt
mv ../wt ../wt-moved-away
touch -d "4 months ago" .git/worktrees/wt/index .git/worktrees/wt/gitdir
kept() { if [ -d "$T/repo/.git/worktrees/wt" ]; then echo kept; else echo PRUNED; fi; }
echo "prunable=$(git worktree list --porcelain | grep -c ^prunable)"
git worktree prune >/dev/null 2>&1; echo "prune=$? $(kept)"
git -C "$T/repo" worktree prune >/dev/null 2>&1; echo "prune_C=$? $(kept)"
git --git-dir="$T/repo/.git" --work-tree="$T/repo" worktree prune >/dev/null 2>&1; echo "prune_gitdir=$? $(kept)"
git -c core.pager=cat --no-pager worktree prune --expire now >/dev/null 2>&1; echo "prune_opts=$? $(kept)"
echo "prune_message=$(git worktree prune 2>&1 | head -1)"
git gc -q >/dev/null 2>&1; echo "gc=$? $(kept)"
git gc -q --prune=now >/dev/null 2>&1; echo "gc_prune_now=$? $(kept)"
git worktree list >/dev/null 2>&1; echo "worktree_list=$?"
git log --oneline >/dev/null 2>&1; echo "log=$?"

# The shared repositories: read only.
for share in "$@"; do
	[ -e "$share/.git" ] || continue
	echo "shared=$share local=$(git -C "$share" config --local --get commit.gpgsign) effective=$(git -C "$share" config --get commit.gpgsign)"
done

cd / && rm -rf "$T"
