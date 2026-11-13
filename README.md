# ubuntu-hardening-as-code

An Ansible role that hardens an Ubuntu 24.04 server in five areas of the CIS
benchmark (network, kernel modules, cron, SSH, auditd), built to be **checked
before it is applied**. It is the public, example-valued version of a role that
runs against a real multi-tenant server; the real values stay in a private repo.

**Inspired by CIS, not a compliance tool.** It covers a small part of the
benchmark and departs from it on purpose in places (see the table below). Use
a scanner if you need a compliance report.

The point is less the settings than how they are verified:

- **Check mode first.** `--check --diff` on a server you already hardened by hand
  should say `changed=0` for the tasks here. That proves the code describes those
  settings, not the whole server.
- **The file and the running value.** A sysctl file can be right while the kernel
  still runs the old value (written, never loaded). The role loads the file,
  then reads the live values and fails if they differ. The same for SSH: for
  sshd the first value wins, so an earlier drop-in can override a correct file;
  the role reads the effective settings (`sshd -T`) and fails if they differ.
- **Negative controls.** A check that always says 0 looks the same as a check that
  compares nothing. The tests break things on purpose and expect them to be caught,
  and `test/mutations.sh` breaks the role itself and expects the tests to fail.
- **Nothing destructive, no lock-out.** An active root key file fails an assert;
  the role never deletes a key. An SSH file that `sshd -t` rejects is never
  written. A run stops before touching SSH if a user in `AllowUsers` does not
  exist or has no key.

## What it sets

| Area | File or setting |
|---|---|
| Network | `/etc/sysctl.d/61-cis-network.conf`: no ICMP redirects sent or accepted, log martians, strict reverse-path filter. Named 61 to load after Ubuntu's `10-network-security.conf` (for sysctl the last file wins). |
| Modules | `/etc/modprobe.d/60-cis-unused-fs.conf`: cramfs, freevxfs, hfs, hfsplus, jffs2, udf, usb-storage cannot load |
| cron | `/etc/cron.allow` (root by default), `/etc/crontab` 600, cron folders 700 |
| SSH | `/etc/ssh/sshd_config` 600; `sshd_config.d/00-hardening.conf` (for sshd the **first** value wins, hence 00): no passwords, no root, `AllowUsers`, no agent or Unix-socket forwarding, `LogLevel VERBOSE` (logs which key logged in), 60 s login window, dead sessions dropped, no SHA-1 or 64-bit MACs. TCP tunnels: off, or local-only to the targets you list. |
| Root key | no `/root/.ssh/authorized_keys` or `authorized_keys2` (assert) |
| auditd | installed, rules in `/etc/audit/rules.d/50-hardening.rules` (identity, sudo, SSH and keys, sysctl, modules, cron, systemd, firewall, time, mounts, permission changes, and every root command run for a logged-in person), log rotation, service running |

All values are variables in `ansible/roles/cis_hardening/defaults/main.yml`.
**Set `cis_hardening_ssh_allow_users` to your own login user first.**

### What it does not cover, and where it departs from CIS

| | |
|---|---|
| Not covered | firewall, users and sudo, password policy, filesystem partitions and mount options, AppArmor, time sync, logging and journald retention, file integrity (AIDE), bootloader, the login banner, Docker |
| Departs on purpose | `AllowTcpForwarding local` + `PermitOpen` instead of `DisableForwarding yes`, when a service is reachable only through `ssh -L`. `ClientAliveInterval 300` x 3 (drops a dead session after about 15 minutes). |
| Honest limit | Forwarding limits are not a security boundary against a user who has a shell (the sshd manual says so): such a user can run their own forwarder. They narrow what a stolen key can do through `ssh -L`/`-R` alone, and they satisfy the benchmark. |
| Audit blind spot to close yourself | Members of the `docker` group can become root without `sudo`, and the `root_cmd` rule does not see that. If you run Docker, add a watch through `cis_hardening_audit_extra_watches` and an execve rule on `/usr/bin/docker`. |

## Use

```bash
cd ansible
sudo ansible-playbook --check --diff site.yml   # read the diff
sudo ansible-playbook site.yml                   # only after reading it
```

The example inventory runs Ansible on the server against itself
(`ansible_connection=local`), which needs no SSH key on another machine. For a
control node, replace the line in `inventory.ini`.

**Before a real run that changes the SSH file on a remote server,** start a timer
that restores the old file, and cancel it only after a new login works:

```bash
sudo cp -p /etc/ssh/sshd_config.d/00-hardening.conf /root/00-hardening.conf.bak
sudo systemd-run --on-active=30min --unit=sshd-revert \
  /bin/sh -c 'cp -p /root/00-hardening.conf.bak /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh'
# ... run, then test a NEW login and every tunnel you rely on ...
sudo systemctl stop sshd-revert.timer
```

Thirty minutes, not ten: when a person has to run the cancel, ten minutes passed
once and the fix undid itself. The timer does not survive a reboot, so do not
start it just before a scheduled one. `sshd -t` validates the new file on its
own; it cannot see a conflict with a `Match` block elsewhere, which is why the
new login is the real test.

## Lessons this role carries

1. **Turning a feature off breaks whoever used it.** Disabling SSH tunnels was
   tested in one direction ("a tunnel is refused") and broke a dashboard whose
   only access was `ssh -L`. Before you disable anything, search for its users and
   add a positive test next to the negative one. That is why tunnels here are a
   list of allowed targets, not just on or off.
2. **A negative test must make the forbidden thing happen.** Opening a tunnel
   succeeds even when tunnels are off; the refusal comes when traffic goes through.
3. **Check mode hides ordering bugs.** The first version compared the kernel with
   the file before the handler that loads the file had run. In check mode on an
   already hardened server that is invisible; a first real run would have failed,
   and every run after it too. Found in review, fixed with `flush_handlers`, and
   now a test (`sysctl-live.sh`) and a mutant cover it.
4. **A default can lock you out.** `AllowUsers admin` with passwords off closes
   the door on a server whose user is `ubuntu`. The role now refuses to run.
5. **Verify against the target, not the textbook.** A comment claimed auditd
   refuses `systemctl restart`. True on some distributions; on Ubuntu 24.04
   `RefuseManualStop=no`.
6. **"Survives a reboot" is only proven by a reboot.** `sysctl --system` showed
   the right values, so the hardening was called reboot-safe. After the first
   real reboot `log_martians` was 0 again: ufw applies its own
   `/etc/ufw/sysctl.conf` when it starts, after systemd has loaded
   `/etc/sysctl.d`, and that file says 0. Every file looked right; the daily
   file-hash audit saw nothing. The live-value comparison caught it the next
   morning. The role now also fixes the line in ufw's file, and a test covers it.

## Tests

```bash
bash test/run-tests.sh    # needs Docker; a few minutes
bash test/mutations.sh    # breaks the role eight ways; every break must be caught
bash test/lint.sh         # yamllint + ansible-lint (production profile)
```

A throwaway Ubuntu 24.04 container plays the server. It has no systemd, so
reloading sshd, loading audit rules into the kernel and starting auditd are
**not** tested (`cis_hardening_in_container=true` skips them).

**Main tests (unprivileged container), 37 checks:**

- check mode on a fresh server without auditd reports changes, fails nothing and
  writes nothing; the first real run installs auditd and changes the server; the
  second changes nothing; check mode then says `changed=0 failed=0`;
- the state is read back from the system (`sshd -T`, `stat`, the files), not from
  Ansible's report; a later `PasswordAuthentication yes` in the main file loses
  to the 00 file;
- an earlier drop-in that re-enables passwords is caught by the effective
  settings check, although the hardening file itself matches;
- drift (`/etc/crontab` set to 644) is reported by check mode, check mode writes
  nothing, and a real run repairs it;
- an empty root key file fails the assert and is not deleted;
- one allowed tunnel target shows up in `sshd -T`; a log count of 7 (Ubuntu's
  default is 5, so 5 would prove nothing) reaches `auditd.conf` exactly once;
- an invalid `PermitOpen` is rejected by `sshd -t` and the live file is unchanged;
- a user without a key, a user that does not exist and an empty user list each
  stop the run, and the SSH file still allows the original user.

**Live sysctl tests (privileged container, only `--tags sysctl`), 7 checks.**
The tasks write only `net.ipv4.conf.*`, which belong to the container's own
network namespace. Check mode on a fresh kernel reports without failing; the
first real run loads the file before comparing; kernel drift with a matching
file is caught.

## Versions

ansible-core 2.21.6 (pinned with its libraries in `test/requirements.txt`),
Ubuntu 24.04. MIT license.
