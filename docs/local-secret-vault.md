# Local Secret Vault

This project normally reads build-time secrets from `.mkosi-secrets/`.
That directory is gitignored and validated before every build, but it
is still plaintext on the build host while it exists.

For an Ansible-vault-style workflow on Debian, keep the durable copy in
an `age`-encrypted JSON file and use the `bin/mkosi-vault-*` helpers to
unlock it only when editing or building.

## Day-Zero Setup

Run the interactive initializer:

```sh
bin/mkosi-vault-init.sh
```

It uses the repo's normal host-dependency helper and will try to
install `age` and `jq` on Debian/Ubuntu hosts unless
`AB_AUTO_INSTALL_DEPS=no` is set.

The initializer offers three modes:

* **Password prompt** — the simplest Debian-native flow. `age` asks for
  a passphrase when encrypting and decrypting the vault.
* **Generated local age identity** — creates or reuses
  `~/.config/mkosi-vault/age/keys.txt` and encrypts to its public
  recipient.
* **Existing age recipient** — useful for team recipients, host keys,
  or an age-compatible hardware-token plugin.

For hardware-backed unlock, plain `age` needs an age-compatible plugin
or identity. FIDO2 SSH keys are not unlocked through `ssh-agent` in
this workflow.

## Edit The Vault

```sh
bin/mkosi-vault-edit.sh
```

The helper decrypts the vault to a temporary file, opens `$EDITOR`
or `vi`, then re-encrypts the vault when the editor exits.

For recipient-encrypted vaults, the initializer stores the generated
identity path in `secrets/mkosi-secrets.json.age.conf`. You can also
pass an identity explicitly:

```sh
bin/mkosi-vault-edit.sh --identity ~/.config/mkosi-vault/age/keys.txt
```

## Vault Schema

The decrypted vault is JSON so the build wrapper can materialize it
with `jq`. Top-level keys map directly to files under
`.mkosi-secrets/`. Per-host overrides live under `hosts.<hostname>`.

```json
{
  "ssh-authorized-keys": "ssh-ed25519 AAAA... hardware-key\n",
  "tailscale-authkey": "tskey-auth-...",
  "cloudflared-token": "eyJhIjoi...",
  "sendgrid-api-key": "SG....",
  "pagerduty-routing-key": "0123456789abcdef0123456789abcdef",
  "healthchecks-ping-url": "https://hc-ping.com/...",
  "wifi-ssid": "example",
  "wifi-psk": "correct horse battery staple",
  "s3-backup-credentials.json": {
    "endpoint": "",
    "accessKeyId": "YOUR_ACCESS_KEY",
    "secretAccessKey": "YOUR_SECRET_KEY",
    "bucket": "your-backup-bucket"
  },
  "users.json": [
    {
      "username": "you",
      "can_login": true,
      "uid": 1000,
      "gid": 1000,
      "primary_group": "you",
      "groups": ["sudo", "audio", "video", "render", "input", "plugdev"],
      "shell": "/bin/bash",
      "password_hash": "$y$j9T$..."
    }
  ],
  "hosts": {
    "myhost": {
      "tailscale-authkey": "tskey-auth-host-specific-...",
      "s3-backup-credentials.json": {
        "endpoint": "",
        "accessKeyId": "HOST_ACCESS_KEY",
        "secretAccessKey": "HOST_SECRET_KEY",
        "bucket": "host-backup-bucket"
      },
      "users.json": [
        {
          "username": "you",
          "can_login": true,
          "uid": 1000,
          "gid": 1000,
          "primary_group": "you",
          "groups": ["sudo", "audio", "video", "render", "input", "plugdev"],
          "shell": "/bin/bash",
          "password_hash": "$y$j9T$HOST_SPECIFIC_HASH"
        }
      ]
    }
  }
}
```

The `users.json` key defines local login accounts baked into the image.
It follows the same schema as the standalone `.users.json` file.
Top-level `users.json` is shared across all hosts; per-host
`hosts.<name>.users.json` replaces the top-level array for that host.
See `docs/user-provisioning.md` for the full field reference.

All other keys are optional except the secrets required by the profiles
you select. `scripts/verify-build-secrets.sh` remains the authority for
required files, formats, and permissions.

## Build With The Vault

```sh
bin/mkosi-vault-build.sh -- --host x1g13
```

The command:

1. decrypts the age file to a temporary file, preferring `/dev/shm`
2. writes `.mkosi-secrets/` with `0700` directories and `0600` files
3. runs `./build.sh` with all arguments after `--`
4. removes `.mkosi-secrets/` again on exit

If `.mkosi-secrets/` already exists, the command refuses to continue.
Use `--replace-staging` only when you intentionally want the generated
vault contents to replace the current plaintext staging tree.

Use `--keep-unlocked` for debugging. Remove `.mkosi-secrets/` manually
afterwards.

## Files

The default setup creates:

* `secrets/mkosi-secrets.json.age` — encrypted vault, safe to commit
* `secrets/mkosi-secrets.json.age.conf` — non-secret mode/identity
  hints, safe to commit if the identity path is not sensitive
* `secrets/mkosi-secrets.json.age.recipients` — public recipient list
  for recipient-encrypted vaults, safe to commit

Plaintext `secrets/*.json` and `.mkosi-secrets/` remain gitignored.

## Security Notes

The vault protects secrets at rest on the build host. During a build,
the existing mkosi pipeline still needs plaintext files in
`.mkosi-secrets/` so it can validate formats, substitute public SSH
keys, and copy service credentials into the image.

Inside the built image, secrets live under `/etc/credstore/` on the
LUKS-encrypted root filesystem and are exposed to services with
systemd `LoadCredential=`.
