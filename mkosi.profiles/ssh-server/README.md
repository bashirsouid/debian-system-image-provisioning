# ssh-server

Persistent `sshd` on port 22 with a hardened configuration baked into the
image. Enables `ssh.service` and masks the conflicting `ssh.socket`.

## Required secrets

| Secret | Vault key | Notes |
| --- | --- | --- |
| `ssh-authorized-keys` | `"ssh-authorized-keys"` | One public key per line, installed into `/etc/ssh/authorized_keys.d/<user>` |

Place this in your secrets vault or at `.mkosi-secrets/ssh-authorized-keys`
(mode 0600). Hardware-backed keys (e.g. FIDO2 / YubiKey) are recommended — see
`docs/remote-access.md`.

## What this profile provides

* `openssh-server` package
* Hardened `sshd_config` drop-in at `/etc/ssh/sshd_config.d/50-hardening.conf`:
  * Password authentication disabled
  * Root login disabled
  * `AllowUsers` restricted to the primary login user (substituted from the
    user definitions at build time)
* Health-check hook — fails the A/B health gate if sshd is not running
