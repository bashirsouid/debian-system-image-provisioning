# .mkosi-secrets/ — build-host secrets staging

This directory is **gitignored** except for this example tree.

`scripts/verify-build-secrets.sh` reads from `.mkosi-secrets/` and
refuses to build if required files are missing, malformed, or
world-readable.

`scripts/package-credentials.sh` reads from `.mkosi-secrets/` and
produces encrypted credential blobs under `mkosi.extra/etc/credstore.encrypted/`.

## Required files

```
.mkosi-secrets/
├── tailscale-authkey         (mode 0600, single line, starts tskey-auth-)
├── cloudflared-token         (mode 0600, single line, base64)
└── ssh-authorized-keys       (mode 0600, authorized_keys format)
```

## Optional secrets (profile-gated)

```
.mkosi-secrets/
└── s3-backup-credentials.json       (mode 0600, JSON format for S3 backup)
```

The format for `s3-backup-credentials.json`:

```json
{
  "endpoint": "",
  "accessKeyId": "YOUR_ACCESS_KEY",
  "secretAccessKey": "YOUR_SECRET_KEY",
  "bucket": "your-backup-bucket"
}
```

- `endpoint` may be empty for AWS S3 default, or a custom S3-compatible URL
- `accessKeyId` and `secretAccessKey` are your S3 credentials
- `bucket` is the destination bucket name

The `s3-unencrypted-backup` profile reads this secret and uploads files
listed in `/etc/s3-backup-paths.conf` (configured via host overlay).

## Optional per-host overrides

```
.mkosi-secrets/
└── hosts/
    ├── evox2/
    │   ├── tailscale-authkey
    │   └── cloudflared-token
    └── macbookpro13-2019-t2/
        └── ssh-authorized-keys
```

If a per-host file exists, it takes precedence over the top-level file
for that host.

## Permissions

The directory itself must be 0700 (or 0750 / 0500). Files must be 0400,
0440, 0600, or 0640. The verify script refuses to continue otherwise.

## Never commit this directory

`.gitignore` must contain:

```
.mkosi-secrets/
!.mkosi-secrets.example/
!.mkosi-secrets.example/**
```

The verify script cross-checks with `git ls-files` and fails the build
if any file under `.mkosi-secrets/` is tracked.
