#!/usr/bin/env bash
# yamllint and ansible-lint in a throwaway container (nothing installed on the host).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if command -v cygpath >/dev/null; then root=$(cygpath -m "$root"); fi
# The copy drops world-write bits: Ansible ignores ansible.cfg in a world-writable folder.
MSYS_NO_PATHCONV=1 docker run --rm -v "$root:/src:ro" python:3.12-slim sh -c '
  pip install -q --root-user-action=ignore --disable-pip-version-check \
    ansible-core==2.21.6 ansible-lint==26.11.0 yamllint==1.38.0 >/dev/null 2>&1
  cp -r /src /w && chmod -R go-w /w && cd /w/ansible
  yamllint -c ../.yamllint . && echo "yamllint: clean"
  ansible-lint --offline site.yml'
