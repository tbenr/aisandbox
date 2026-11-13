# Shared helpers for the test suites. Sourced, not run.
# Written for the bash that ships with macOS (3.2): no associative arrays.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MACHINE=${AISANDBOX_MACHINE:-AIsandbox}
AISB=$REPO/aisandbox
REAL_ORB=$(command -v orb || true)     # remembered before any stub goes into PATH
REAL_SSH=/usr/bin/ssh

PASS=0
FAIL=0

section() { printf '\n== %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

# is "what is being checked" "<got>" "<wanted>"
is() {
	if [ "$2" = "$3" ]; then pass "$1"
	else fail "$1"; printf '          got:    [%s]\n          wanted: [%s]\n' "$2" "$3"; fi
}

# like "what is being checked" "<text>" "<extended regex that must match>"
like() {
	if printf '%s\n' "$2" | grep -Eq -- "$3"; then pass "$1"
	else fail "$1"; printf '          wanted a match for: %s\n          in:\n' "$3"; printf '%s\n' "$2" | sed 's/^/            /'; fi
}

# unlike "what is being checked" "<text>" "<extended regex that must not match>"
unlike() {
	if printf '%s\n' "$2" | grep -Eq -- "$3"; then fail "$1"; printf '          did not want a match for: %s\n          in:\n' "$3"; printf '%s\n' "$2" | sed 's/^/            /'
	else pass "$1"; fi
}

# Commands inside the VM, as root and as the agent user.
root() { "$REAL_ORB" -m "$MACHINE" -u root "$@" </dev/null; }
agent() { "$REAL_ORB" -m "$MACHINE" "$@" </dev/null; }

need_orb() {
	[ -n "$REAL_ORB" ] || { echo "orb is not installed"; exit 2; }
}

need_vm() {
	need_orb
	"$REAL_ORB" list -r -q 2>/dev/null | grep -qx -- "$MACHINE" \
		|| { echo "$MACHINE is not running; start it with: aisandbox up"; exit 2; }
}

# A scratch directory on the Mac, removed when the suite ends. The path is
# kept short: ssh control sockets have a length limit.
TMP=
make_tmp() {
	TMP=$(mktemp -d "${TMPDIR:-/tmp}/aisbt.XXXXXX")
}

finish() {
	printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
	[ "$FAIL" = 0 ]
}
