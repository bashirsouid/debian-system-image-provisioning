# Security hardening walkthrough

Apply these in order. Each step is independently reversible by
dropping a same-named override into a host overlay. Build, deploy,
validate before moving to the next step.

## 1. Kernel sysctls + module blacklist (one rebuild, low risk)

Files: `/etc/sysctl.d/95-ab-kernel-hardening.conf`,
`/etc/modprobe.d/ab-blacklist.conf`

What breaks:
- Anything that relied on unprivileged BPF (rare on a home host).
- Debuggers attaching to non-child processes (you can `sudo` first,
  or temporarily set `kernel.yama.ptrace_scope=0`).
- Obscure filesystems (cramfs, hfs, udf) are gone unless you
  `modprobe -r` them first — intentional.

Rollback: host overlay with `kernel.unprivileged_bpf_disabled=0` or
individual `install cramfs cramfs` lines.

## 2. nftables baseline (one rebuild, medium risk)

File: `/etc/nftables.conf`

What breaks:
- Anything listening on a port that is not in the allow list. Home
  Assistant on 8123 is the most likely casualty. Add a per-host
  drop-in before deploying.
- Inbound ICMP is rate-limited to 4/s; some monitoring tools flood
  and will miss responses. Not a problem for humans.

Rollback: host overlay that replaces the `input` chain policy to
`accept`.

How to add Home Assistant on the LAN only:

```
# hosts/homeassistant/mkosi.extra/etc/nftables.conf.d/50-ha.nft
table inet filter {
    chain input {
        tcp dport 8123 ip saddr { 192.168.0.0/16, 10.0.0.0/8 } \
            accept comment "Home Assistant on LAN"
    }
}
```

## 3. sudoers hardening (one rebuild, low risk)

File: `/etc/sudoers.d/90-ab-hardening`

What breaks:
- Cron jobs that `sudo` something from a non-tty context: `requiretty`
  blocks them. Workaround: `Defaults:root !requiretty` for the service
  account doing the cron call, or use a systemd timer instead.
- `sudo some-cmd &` in a detached session: `use_pty` blocks this.
  Real interactive use is unaffected.
- The shorter `timestamp_timeout=5` means you re-type your password
  every 5 minutes instead of 15. Minor inconvenience.

Rollback: remove `/etc/sudoers.d/90-ab-hardening`. On the running
host: `sudo visudo -f /etc/sudoers.d/90-ab-hardening` and delete
specific `Defaults` lines.

## 4. DNS hardening: DoT + DNSSEC (one rebuild, medium risk)

File: `/etc/systemd/resolved.conf.d/10-ab-hardening.conf`

What breaks:
- Home networks with DNSSEC-breaking middleboxes (some ISP CPE
  routers, captive portals). Symptom: resolving anything fails with
  "DNSSEC validation failed".
- Corporate VPNs that push their own internal DNS for split horizon
  names. Workaround: let Tailscale's MagicDNS push the internal
  names via `Domains=`.

Rollback on the live host: edit the file, set `DNSSEC=allow-downgrade`,
restart `systemd-resolved`. Rebuild next cycle.

## 5. systemd-oomd (one rebuild, low risk)

File: `/etc/systemd/oomd.conf.d/10-ab.conf`

What breaks:
- Nothing, if your Home Assistant / browser / dev workloads fit in
  RAM. Under pressure, oomd will kill the heaviest user cgroup. If
  that is your only browser, you will notice.

To protect specific services from being killed, in their unit
(drop-in `~override.conf`):

```
[Service]
ManagedOOMMemoryPressure=auto        # default; oomd ignores this cgroup
```

And to mark a cgroup as preferred victim (e.g. the user session):

```
# /etc/systemd/system/[email protected]/50-oom.conf
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
```

## 6. Coredump off (one rebuild, zero risk)

File: `/etc/systemd/coredump.conf.d/10-ab.conf`

What breaks: nothing; you lose the ability to generate a post-mortem
coredump from a crashing service, but you gain "decrypted auth keys
cannot land in /var/lib/systemd/coredump/". If you need a core for
debugging a specific service temporarily, edit in place and
`systemctl daemon-reexec`.

## 7. security/limits.d (one rebuild, low risk)

File: `/etc/security/limits.d/90-ab-hardening.conf`

What breaks: a forked process spawning more than 4096 children per
user will hit the limit. Real workstations never do this; container
hosts often do. Bump `nproc` per-host if it bites.

## 8. PAM-U2F for sudo (two-step; HIGH risk without backup key)

Files: `/etc/pam.d/sudo-u2f`, `/usr/local/sbin/ab-enable-pam-u2f`

Workflow:

1. On the host, run `sudo ab-enable-pam-u2f`. This enrolls your
   YubiKey and writes `/var/lib/ab-pam-u2f/u2f_mappings`. It does
   NOT turn on enforcement.
2. Repeat with a SECOND YubiKey. Do not skip this. Mapping file
   will now have two lines for your user.
3. Copy the mapping file into the build tree:
   `.mkosi-secrets/hosts/<host>/u2f-mappings`.
4. Rebuild with `AB_ENABLE_PAM_U2F=yes`. The build installs the
   mapping at `/etc/u2f_mappings` and wires `pam_u2f.so` into the
   image's `/etc/pam.d/sudo`.
5. Deploy via sysupdate. Reboot. Test sudo over the Cloudflare
   Tunnel SSH path (primary) AND via a local login, with BOTH
   YubiKeys, before you close the session you sudo'd from.

Recovery path if both YubiKeys are unavailable:
- SSH in via whichever path still works.
- Put the old image back via `bootctl set-default` and reboot —
  PAM-U2F was introduced in the newer image.

## 9. TPM-bound /home and /mnt/data (phase; HIGH risk, plan downtime)

See `docs/secure-boot-roadmap.md` section "Phase 4". Requires:

1. LUKS-format the partition (destructive).
2. Restore data from backup.
3. Run `ab-enroll-tpm-unlock` to add TPM2 slot.
4. Add crypttab entry.
5. Test reboot.
6. Verify recovery passphrase still works.

## 10. Secure Boot + RootVerity (phase; one-time firmware trip)

See `docs/secure-boot-roadmap.md` sections "Phase 1-3". This is the
big one and requires physical access to each host.

## What to test after every step

```
sudo ab-monitor-status         # nothing lit up red?
systemctl --failed             # nothing broke?
sudo ab-remote-access-status   # can you still get back in?
journalctl -p err -b -n 50     # new errors since boot?
```

If any of these look wrong, roll back via A/B before touching the
next step.
