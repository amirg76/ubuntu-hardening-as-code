#!/usr/bin/env bash
# Runs inside the test container (unprivileged: /proc/sys is read-only, so the
# live sysctl part is tested separately by sysctl-live.sh).
# Every check is printed as PASS or FAIL; the exit code is the number of failures.
set -u
cp -r /src /w && cd /w || exit 99
# Mutation testing (test/mutations.sh): break the copy on purpose.
if [ -n "${MUTATE_SED:-}" ]; then
  cp "$MUTATE_FILE" /tmp/before-mutation
  sed -i "$MUTATE_SED" "$MUTATE_FILE"
  cmp -s "$MUTATE_FILE" /tmp/before-mutation && { echo "MUTATION DID NOT APPLY"; exit 98; }
fi
export ANSIBLE_FORCE_COLOR=0
C='{"cis_hardening_in_container": true, "cis_hardening_sysctl_live": false}'
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
# "changed" or "failed" count from the recap line of a run's output file
recap() { grep -E '^localhost +:' "$1" | sed -E "s/.* $2=([0-9]+).*/\1/"; }
play() { # $1 output file, rest: extra arguments
  local out=$1; shift
  ansible-playbook site.yml -e "$C" "$@" >"$out" 2>&1
}
sshd_val() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }
SSHF=/etc/ssh/sshd_config.d/00-hardening.conf

# The login user of this "server": exists and has a key, as the preflight demands.
useradd -m admin
install -d -m 700 -o admin -g admin /home/admin/.ssh
ssh-keygen -q -t ed25519 -N '' -f /tmp/testkey
install -m 600 -o admin -g admin /tmp/testkey.pub /home/admin/.ssh/authorized_keys

# A firewall sysctl file as ufw ships it: it turns martian logging off at boot.
# It has no line for "default": the role must change what exists and add nothing.
mkdir -p /etc/ufw
printf '%s\n' 'net/ipv4/icmp_echo_ignore_all=0' 'net/ipv4/conf/all/log_martians=0' > /etc/ufw/sysctl.conf

# 1. Check mode on a fresh server (auditd not installed): a report, not an error.
dpkg-query -W auditd >/dev/null 2>&1 && fail "control: auditd is preinstalled, the fresh-server path is not tested" \
  || pass "control: auditd is not installed yet"
play /tmp/r0 --check --diff
[ "$(recap /tmp/r0 failed)" = 0 ] && [ "$(recap /tmp/r0 changed)" -gt 0 ] \
  && pass "check mode on a fresh server: reports changes, 0 failed (changed=$(recap /tmp/r0 changed))" \
  || { fail "check mode on a fresh server"; grep -E 'fatal|FAILED' /tmp/r0 | cut -c1-300; }
[ ! -e /etc/cron.allow ] && [ ! -e "$SSHF" ] && pass "check mode wrote nothing on the fresh server" || fail "check mode wrote files"

# 2. First real run changes the fresh server.
play /tmp/r1
[ "$(recap /tmp/r1 failed)" = 0 ] && [ "$(recap /tmp/r1 changed)" -gt 0 ] \
  && pass "first run: changes applied, 0 failed (changed=$(recap /tmp/r1 changed))" \
  || { fail "first run"; grep -E 'fatal|FAILED' /tmp/r1 | cut -c1-300; }
dpkg-query -W -f='${Status}' auditd 2>/dev/null | grep -q 'install ok installed' \
  && pass "auditd installed by the role" || fail "auditd not installed"

[ "$(cat /etc/ufw/sysctl.conf)" = "$(printf '%s\n' 'net/ipv4/icmp_echo_ignore_all=0' 'net/ipv4/conf/all/log_martians=1')" ] \
  && pass "the firewall's sysctl file no longer undoes log_martians; nothing else changed or added" \
  || { fail "firewall sysctl file"; cat /etc/ufw/sysctl.conf; }

# 3. Second run changes nothing (idempotent).
play /tmp/r2
[ "$(recap /tmp/r2 changed)" = 0 ] && [ "$(recap /tmp/r2 failed)" = 0 ] \
  && pass "second run: changed=0 failed=0" || { fail "second run not idempotent"; grep -E '^(changed|fatal)' /tmp/r2; }

# 4. Check mode on the hardened server: nothing to change.
play /tmp/r3 --check --diff
[ "$(recap /tmp/r3 changed)" = 0 ] && [ "$(recap /tmp/r3 failed)" = 0 ] \
  && pass "check mode: changed=0 failed=0" || fail "check mode reports changes or failures"

# 5. The server really is in the stated state (read from the system, not from Ansible).
[ "$(sshd_val allowtcpforwarding)" = no ] && pass "sshd: TCP tunnels off by default" || fail "sshd allowtcpforwarding"
[ "$(sshd_val allowstreamlocalforwarding)" = no ] && pass "sshd: Unix-socket tunnels off" || fail "sshd allowstreamlocalforwarding"
[ "$(sshd_val passwordauthentication)" = no ] && pass "sshd: no passwords" || fail "sshd passwordauthentication"
[ "$(sshd_val allowusers)" = admin ] && pass "sshd: AllowUsers admin" || fail "sshd allowusers"
[ "$(sshd_val loglevel)" = VERBOSE ] && pass "sshd: LogLevel VERBOSE" || fail "sshd loglevel"
[ "$(stat -c %a /etc/crontab)" = 600 ] && pass "crontab 600" || fail "crontab mode"
[ "$(stat -c %a /etc/cron.d)" = 700 ] && pass "cron.d 700" || fail "cron.d mode"
[ "$(cat /etc/cron.allow)" = root ] && pass "cron.allow = root" || fail "cron.allow"
grep -q -- '-k root_cmd' /etc/audit/rules.d/50-hardening.rules && pass "audit rules written" || fail "audit rules"
grep -q -- '-w /home/admin/.ssh ' /etc/audit/rules.d/50-hardening.rules && pass "audit rules watch the login user's keys" || fail "audit rule for user keys"
grep -qx 'install usb-storage /bin/false' /etc/modprobe.d/60-cis-unused-fs.conf && pass "usb-storage blocked" || fail "modprobe file"

# 6. "The first value wins": a later, weaker line in the main file must lose.
echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
[ "$(sshd_val passwordauthentication)" = no ] && pass "a later 'PasswordAuthentication yes' in sshd_config loses" || fail "first-value-wins"
sed -i '$ d' /etc/ssh/sshd_config

# 6b. Negative control: a drop-in that sorts BEFORE the hardening file wins, so the
#     file is right and the server is not. Only "sshd -T" shows it.
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/00-a-earlier.conf
play /tmp/r4b --check
[ "$(recap /tmp/r4b changed)" = 0 ] && [ "$(recap /tmp/r4b failed)" = 1 ] \
  && grep -q "sshd -T does not say 'passwordauthentication no'" /tmp/r4b \
  && pass "an earlier drop-in that re-enables passwords is caught although the file matches" \
  || { fail "overriding drop-in not caught"; grep -E '^localhost' /tmp/r4b; }
rm -f /etc/ssh/sshd_config.d/00-a-earlier.conf

# 7. Negative control: drift on the server must show up in check mode.
chmod 644 /etc/crontab
play /tmp/r5 --check --diff
[ "$(recap /tmp/r5 changed)" = 1 ] \
  && awk '/^TASK /{t=($0 ~ /Crontab readable by root only/)} t && /^changed/{f=1} END{exit !f}' /tmp/r5 \
  && pass "drift caught: crontab 644 reported by the crontab task" || { fail "drift not caught"; grep -E '^(changed|localhost)' /tmp/r5; }
[ "$(stat -c %a /etc/crontab)" = 644 ] && pass "check mode wrote nothing (crontab still 644)" || fail "check mode changed the file"
play /tmp/r5b
[ "$(stat -c %a /etc/crontab)" = 600 ] && pass "real run repaired the drift" || fail "repair"

# 8. Negative control: an active root key file fails the assert, and is not deleted.
mkdir -p /root/.ssh && : > /root/.ssh/authorized_keys
play /tmp/r6 --check
[ "$(recap /tmp/r6 failed)" = 1 ] && grep -q 'root can log in with a key' /tmp/r6 \
  && pass "root key file caught" || fail "root key assert"
[ -f /root/.ssh/authorized_keys ] && pass "the key file was not deleted" || fail "key file deleted"
rm -f /root/.ssh/authorized_keys

# 9. Variables reach the system. Ubuntu's own auditd.conf already says
#    num_logs = 5, so 5 would prove nothing: use 7.
grep -qx 'num_logs = 7' /etc/audit/auditd.conf \
  && fail "auditd.conf already says 7: the next check would prove nothing" \
  || pass "control: auditd.conf does not say 7 yet"
play /tmp/r7 -e '{"cis_hardening_ssh_permit_open": ["10.0.0.5:8080"], "cis_hardening_auditd_num_logs": 7}'
grep -qx 'num_logs = 7' /etc/audit/auditd.conf && pass "auditd log count set from the variable (7)" || fail "auditd num_logs"
[ "$(grep -c '^num_logs' /etc/audit/auditd.conf)" = 1 ] && pass "num_logs appears once (no duplicate line)" || fail "duplicate num_logs"
[ "$(sshd_val allowtcpforwarding)" = local ] && [ "$(sshd_val permitopen)" = 10.0.0.5:8080 ] \
  && pass "sshd: local tunnels to 10.0.0.5:8080 only" || fail "permitopen"

# 10. Negative control: an SSH file that sshd rejects is never written.
before=$(sha256sum "$SSHF" 2>/dev/null || echo missing)
[ "$before" != missing ] && pass "control: the sshd file exists before the bad write" || fail "sshd file missing before the bad write"
play /tmp/r8 -e '{"cis_hardening_ssh_permit_open": ["not a target"]}'
[ "$(recap /tmp/r8 failed)" = 1 ] && grep -q '"msg": "failed to validate"' /tmp/r8 \
  && grep -q 'PermitOpen bad port number' /tmp/r8 \
  && pass "invalid sshd file rejected by validation" || { fail "validation"; grep -E 'fatal|msg' /tmp/r8 | head -3; }
[ "$(sha256sum "$SSHF" 2>/dev/null || echo missing)" = "$before" ] \
  && pass "the live sshd file is unchanged after the rejected write" || fail "sshd file changed"

# 11. Negative controls: the preflight refuses a run that would lock a user out.
useradd -m nokey
play /tmp/r9 -e '{"cis_hardening_ssh_allow_users": ["nokey"]}'
[ "$(recap /tmp/r9 failed)" = 1 ] && grep -q 'would lock that user out' /tmp/r9 \
  && pass "a user without a key stops the run" || { fail "preflight: user without key"; grep -E '^localhost' /tmp/r9; }
play /tmp/r10 -e '{"cis_hardening_ssh_allow_users": ["ghost"]}'
[ "$(recap /tmp/r10 failed)" = 1 ] && grep -q 'would lock that user out' /tmp/r10 \
  && pass "a user that does not exist stops the run" || fail "preflight: missing user"
play /tmp/r11 -e '{"cis_hardening_ssh_allow_users": []}'
[ "$(recap /tmp/r11 failed)" = 1 ] && grep -q 'nobody could log in' /tmp/r11 \
  && pass "an empty user list stops the run" || fail "preflight: empty list"
[ "$(sha256sum "$SSHF" 2>/dev/null || echo missing)" = "$before" ] && [ "$(sshd_val allowusers)" = admin ] \
  && pass "after the three refused runs the sshd file still allows admin" || fail "sshd file changed by a refused run"

echo "failures: $fails"
exit "$fails"
