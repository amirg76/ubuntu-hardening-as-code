#!/usr/bin/env bash
# Runs inside a PRIVILEGED test container, where /proc/sys is writable. Only the
# sysctl tasks run (--tags sysctl), and they write only net.ipv4.conf.* values,
# which belong to the container's own network namespace, not to the host.
set -u
cp -r /src /w && cd /w || exit 99
if [ -n "${MUTATE_SED:-}" ]; then
  cp "$MUTATE_FILE" /tmp/before-mutation
  sed -i "$MUTATE_SED" "$MUTATE_FILE"
  cmp -s "$MUTATE_FILE" /tmp/before-mutation && { echo "MUTATION DID NOT APPLY"; exit 98; }
fi
export ANSIBLE_FORCE_COLOR=0
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
recap() { grep -E '^localhost +:' "$1" | sed -E "s/.* $2=([0-9]+).*/\1/"; }
play() { local out=$1; shift; ansible-playbook site.yml --tags sysctl -e '{"cis_hardening_in_container": true}' "$@" >"$out" 2>&1; }
K=net.ipv4.conf.all.send_redirects

[ "$(sysctl -n $K)" = 1 ] && pass "control: the fresh kernel value differs from the wanted one ($K=1)" \
  || fail "control: $K is already 0, the test would prove nothing"

# Check mode on a fresh server: the file would change, so the kernel comparison
# is skipped and the run reports instead of failing.
play /tmp/s0 --check --diff
[ "$(recap /tmp/s0 failed)" = 0 ] && [ "$(recap /tmp/s0 changed)" = 1 ] \
  && pass "check mode on a fresh server: file reported as changed, 0 failed" || { fail "check mode fresh"; tail -5 /tmp/s0; }
[ "$(sysctl -n $K)" = 1 ] && pass "check mode did not touch the kernel" || fail "check mode changed the kernel"

# First real run: the file is written AND loaded before the comparison.
play /tmp/s1
[ "$(recap /tmp/s1 failed)" = 0 ] && pass "first real run: 0 failed" || { fail "first real run fails (file written but not loaded before the comparison)"; grep -E 'fatal|failed:' /tmp/s1 | cut -c1-200 | head -3; }
[ "$(sysctl -n $K)" = 0 ] && [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = 1 ] \
  && pass "the kernel runs the new values" || fail "kernel values not loaded"

play /tmp/s2
[ "$(recap /tmp/s2 changed)" = 0 ] && [ "$(recap /tmp/s2 failed)" = 0 ] && pass "second run: changed=0 failed=0" || fail "second run"

# Negative control: the file is right but the kernel drifted.
sysctl -q -w $K=1
play /tmp/s3 --check
[ "$(recap /tmp/s3 failed)" = 1 ] && grep -q "$K is 1 in the kernel, 0 in the file" /tmp/s3 \
  && pass "kernel drift caught although the file matches" || { fail "kernel drift not caught"; tail -4 /tmp/s3; }

echo "failures: $fails"
exit "$fails"
