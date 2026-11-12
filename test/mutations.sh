#!/usr/bin/env bash
# Test the tests: break the role on purpose and expect the suite to fail.
# The break is applied to the copy inside the container, never to the repo.
# A mutant that survives means a test that proves nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=roles/cis_hardening/tasks/main.yml
S=roles/cis_hardening/templates/00-hardening.conf.j2
survived=0
mutant() { # $1 name, $2 file, $3 sed expression
  local out
  out=$(MUTATE_FILE=$2 MUTATE_SED=$3 bash "$here/run-tests.sh" 2>&1)
  if grep -q 'MUTATION DID NOT APPLY' <<<"$out"; then
    echo "BROKEN    $1: the mutation did not change the file"; survived=$((survived + 1))
  elif grep -q '^FAIL' <<<"$out"; then
    echo "CAUGHT    $1: $(grep -c '^FAIL' <<<"$out") failing check(s), first: $(grep -m1 '^FAIL' <<<"$out" | cut -c7-80)"
  else
    echo "SURVIVED  $1"; survived=$((survived + 1))
  fi
}
mutant "sshd file written without validation" "$T" '/validate: \/usr\/sbin\/sshd -t -f %s/d'
mutant "crontab mode 644"                     "$T" '/path: \/etc\/crontab/,/mode:/ s/mode: "0600"/mode: "0644"/'
mutant "root key assert always true"          "$T" 's/that: not item.stat.exists/that: true/'
mutant "sysctl file not loaded before the comparison" "$T" 's/ansible.builtin.meta: flush_handlers/ansible.builtin.meta: noop/'
mutant "preflight accepts any user"           "$T" 's/^      - item\.\(item\.rc == 0\|stat\.exists\|stat\.size > 0\)$/      - true/'
mutant "Unix-socket tunnels left on"          "$S" '/AllowStreamLocalForwarding no/d'
echo "survived: $survived"
exit "$survived"
