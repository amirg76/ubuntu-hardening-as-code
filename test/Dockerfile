# A throwaway Ubuntu 24.04 "server" for the role's tests. No systemd: the role
# runs with cis_hardening_in_container=true. auditd is NOT preinstalled, so the
# tests cover a server that does not have it yet. The apt lists are kept so
# check mode can see that the package exists.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv python3-apt openssh-server cron kmod procps \
 && mkdir -p /run/sshd
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir --disable-pip-version-check -r /tmp/requirements.txt
ENV PATH=/opt/ansible/bin:$PATH
