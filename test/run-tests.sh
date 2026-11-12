#!/usr/bin/env bash
# Build a throwaway Ubuntu 24.04 container and run the role's tests in it.
# Needs Docker. Nothing touches the host: the code is mounted read-only.
#   1. in-container.sh  unprivileged: everything except live kernel values
#   2. sysctl-live.sh   privileged: only the sysctl tasks, which write only
#                       net.ipv4.conf.* inside the container's network namespace
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
docker build -q -t ubuntu-hardening-test "$here" >/dev/null || exit 97
# Git Bash on Windows: Docker needs E:/... paths, and MSYS_NO_PATHCONV stops
# Git Bash from rewriting the /src paths inside the container.
if command -v cygpath >/dev/null; then root=$(cygpath -m "$root"); here=$(cygpath -m "$here"); fi
export MSYS_NO_PATHCONV=1
mut=(-e "MUTATE_FILE=${MUTATE_FILE:-}" -e "MUTATE_SED=${MUTATE_SED:-}")
rc=0
echo "== main tests"
docker run --rm "${mut[@]}" -v "$root/ansible:/src:ro" -v "$here/in-container.sh:/t.sh:ro" \
  ubuntu-hardening-test bash /t.sh || rc=1
echo "== live sysctl tests"
docker run --rm --privileged "${mut[@]}" -v "$root/ansible:/src:ro" -v "$here/sysctl-live.sh:/t.sh:ro" \
  ubuntu-hardening-test bash /t.sh || rc=1
exit $rc
