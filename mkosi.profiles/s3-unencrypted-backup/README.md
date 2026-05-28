# S3 Unencrypted Backup Profile

## Overview

The `s3-unencrypted-backup` profile installs a systemd timer that periodically uploads configured files to S3-compatible storage. This is designed for backing up already-encrypted key files - the profile itself does NOT encrypt data.

## Features

- **Hourly backup schedule** via systemd timer (`OnCalendar=hourly`)
- **Checksum deduplication** - files are only uploaded if they differ from remote copies
- **Glob pattern support** - paths like `/etc/keys/*.key` are expanded
- **S3-compatible endpoints** - works with AWS S3, MinIO, Backblaze B2, etc.
- **Per-host isolation** - uploads go to `backup/<hostname>/` prefix automatically

## File layout

```
mkosi.profiles/
└─ s3-unencrypted-backup/
   ├─ mkosi.conf                            # installs mc, openssl, jq
   ├─ profile.manifest                       # declares s3 secret requirement
   ├─ mkosi.extra/
   │   ├─ etc/systemd/system/
   │   │   ├─ s3-backup.service             # upload service
   │   │   └─ s3-backup.timer               # hourly timer
   │   ├─ etc/systemd/system-preset/
   │   │   └─ 96-s3-unencrypted-backup.preset
   │   ├─ etc/default/s3-backup             # optional runtime config
   │   └─ usr/local/bin/
   │       └─ s3-backup-trigger             # backup script
   └─ README.md                             # (this file)
```

## Secret format

Create `.mkosi-secrets/s3-credentials.json` (mode 0600):

```json
{
  "endpoint": "",
  "accessKeyId": "YOUR_ACCESS_KEY",
  "secretAccessKey": "YOUR_SECRET_KEY",
  "bucket": "your-backup-bucket"
}
```

- `endpoint`: May be empty for AWS S3 default, or a custom S3-compatible URL (e.g., `https://s3.us-west-002.backblazeb2.com`)
- `accessKeyId` and `secretAccessKey`: Your S3 credentials
- `bucket`: The destination bucket name

## Host configuration

Create `hosts/<name>/mkosi.extra/etc/s3-backup-paths.conf` (one path per line):

```
# Space-separated paths work too
/etc/ssh/ssh_host_ed25519_key.pub
/root/.ssh/id_*.pub
/home/bashirs/.gnupg/*.txt
```

Paths can be:
- Single files
- Directories (uploaded recursively with structure preserved)
- Glob patterns (expanded at upload time)

## How it works

1. On boot (and hourly thereafter), `s3-backup.timer` triggers `s3-backup.service`
2. The service runs `/usr/local/bin/backup-trigger` which:
   - Loads credentials via systemd's `LoadCredential=`
   - Configures `mc` (MinIO client) for S3 access
   - Reads `/etc/s3-backup-paths.conf` for the list of paths
   - For each path, calculates MD5 checksum and compares to remote ETag
   - Uploads only files that differ or don't exist remotely
3. Files are stored under `backup/<hostname>/<relative-path>` in the bucket

## Systemd units

| Unit | Description | When enabled |
|------|-------------|--------------|
| `s3-backup.service` | Executes the backup script | Enabled by default |
| `s3-backup.timer` | Triggers service hourly | Enabled by default |

## Enabling / Disabling

- **Enable for a host**: Add `s3-unencrypted-backup` to `hosts/<name>/profile.default`
- **Disable on a system**: `systemctl disable --now s3-backup.timer`
- **Skip on a specific run**: Remove or rename `/etc/s3-backup-paths.conf`

## Troubleshooting

1. **No files uploaded**: Check that `/etc/s3-backup-paths.conf` exists and contains valid paths
2. **Credential errors**: Verify `.mkosi-secrets/s3-credentials.json` has all required fields
3. **Upload failures**: Check `journalctl -u s3-backup.service` for detailed error messages
4. **Checksum mismatches**: The script uses MD5 for ETag comparison - multipart uploads will always re-upload (ETag format differs)

## License

This profile is part of the *my-mkosi-test* repository and is distributed under the same license as the rest of the project.

---

*End of file*