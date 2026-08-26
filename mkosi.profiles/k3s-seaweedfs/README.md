# k3s-seaweedfs

**SeaweedFS** S3-compatible object store deployed via k3s single-node cluster.
Runs in single-process mode (`weed server`) combining master, volume server,
filer, and S3 gateway in one container. Data persists on the DATA partition
(`/mnt/data/seaweedfs` via `hostPath` + `symlink-k3s` + `data-disk`).

## Why SeaweedFS?

MinIO's community edition was archived upstream (April 2026): no more
binaries, images, or feature development. SeaweedFS (Apache 2.0, active,
12+ years, multi-arch images, used by Kubeflow as default object store) is the
recommended replacement for new single-node S3 deployments.

## What this profile ships

| File | Purpose |
| --- | --- |
| `Packages=` | `jq` — needed by the first-boot credential renderer. |
| `/var/lib/rancher/k3s/server/manifests/seaweedfs.yaml` | Multi-doc YAML: Deployment (chrislusf/seaweedfs:4.44), two NodePort Services (30090→8333 S3 API, 30091→9333 Master UI). The S3 credential Secret (`seaweedfs-s3-config`) is rendered at first boot by `ab-k3s-seaweedfs-creds.service`. k3s applies this on startup. |
| `/usr/local/libexec/ab-k3s-seaweedfs-render-creds` | First-boot oneshot: reads `/etc/credstore/seaweedfs-s3-credentials.json`, renders the real `seaweedfs-s3-config` Secret manifest into the k3s auto-deploy dir. |
| `/etc/systemd/system/ab-k3s-seaweedfs-creds.service` | Oneshot, `After=local-fs.target ab-symlink-k3s.service`, `Before=k3s-install.service k3s.service`, `ConditionPathExists=/etc/credstore/seaweedfs-s3-credentials.json`. |
| `/etc/systemd/system-preset/91-k3s-seaweedfs.preset` | `enable ab-k3s-seaweedfs-creds.service`. |

## How it works

1. Image build bakes the static manifest (Deployment + two NodePort Services) into `/var/lib/rancher/k3s/server/manifests/seaweedfs.yaml`.
2. At first boot, `symlink-k3s` (if selected) adopts the manifest into `/mnt/data/k3s/server/manifests/` **before** k3s starts.
3. `ab-k3s-seaweedfs-creds.service` runs, reads the credential from `/etc/credstore/seaweedfs-s3-credentials.json` (packaged from the age vault), and writes `/var/lib/rancher/k3s/server/manifests/seaweedfs-s3-config.yaml` (the k8s Secret with the real S3 identity config).
4. `k3s-install.service` installs k3s; `k3s.service` starts and auto-applies both manifests → Deployment + NodePort Services + Secret come up.
5. SeaweedFS runs `weed server -dir=/data -s3 …` with the mounted S3 config.
6. Data written to `/data` inside the container lands on `/mnt/data/seaweedfs` (hostPath, DATA partition) — survives A/B root swaps.

## Dependencies

| Profile | Why |
| --- | --- |
| `k3s` | The cluster runtime. |
| `symlink-k3s` | Persists `/var/lib/rancher/k3s` → `/mnt/data/k3s` so manifests and k3s state survive A/B swaps. |
| `data-disk` (or `data-partition`) | Provides `/mnt/data` on a separate block device (cloudbox uses `data-disk` on `/dev/sdb`). |

`requires="k3s"` in `profile.manifest` pulls k3s transitively; the other two are added to the host descriptor explicitly.

## Credentials

Add `seaweedfs-s3-credentials.json` to your age vault (`.mkosi-secrets/` or SOPS vault, same format as `kopia-s3-creds-*.json`):

```json
{
  "accessKeyId": "YOUR_ACCESS_KEY",
  "secretAccessKey": "YOUR_SECRET_KEY"
}
```

Generate strong keys:
```bash
openssl rand -hex 32  # for accessKeyId
openssl rand -hex 32  # for secretAccessKey
```

At build time, `scripts/package-credentials.sh` (gated on `k3s-seaweedfs` profile) stages this file to `/etc/credstore/seaweedfs-s3-credentials.json` (mode 0600). If the secret is absent, the service no-ops with a warning; the pod will fail to start until credentials are provided and the image is rebuilt.

## Architecture

- `chrislusf/seaweedfs:4.44` is multi-arch (amd64 + arm64) — works on cloudbox (arm64) and any amd64 host.
- No architecture pinning in this profile; the descriptor's `Architecture=` drives apt/Docker selection at build time.
- Note: `-fileSizeLimitMB=256` caps maximum single-object size to 256 MiB. Raise if larger uploads are needed.

## Exposure (current: Tailscale-only)

The base nftables firewall accepts all traffic on the `tailscale0` interface. No additional firewall rules are needed. From any machine on your tailnet:

```bash
# S3 API (mc, aws-cli, kopia, etc.)
mc alias set seaweedfs http://<tailscale-ip>:30090 <accessKeyId> <secretAccessKey>
mc ls seaweedfs/

# Master status UI (read-only cluster/volume overview)
curl http://<tailscale-ip>:30091
```

Caddy TLS fronting with dedicated subdomains (e.g. `s3.example.com`, `console.example.com`) is a follow-up — add descriptor keys and extend `host-descriptor.sh` when ready.

## Verify after boot

```bash
# k3s pods
k3s kubectl get pods -A -l app=seaweedfs

# Services show NodePorts 30090 (S3) and 30091 (UI)
k3s kubectl get svc -A -l app=seaweedfs

# Check the rendered Secret exists
k3s kubectl get secret seaweedfs-s3-config -o yaml

# From tailnet client:
mc alias set seaweedfs http://<tailscale-ip>:30090 <accessKeyId> <secretAccessKey>
mc mb seaweedfs/test-bucket
echo hello | mc pipe seaweedfs/test-bucket/hello.txt
mc cat seaweedfs/test-bucket/hello.txt
```

## Troubleshooting

1. **Pod stuck in CreateContainerConfigError / ImagePullBackOff**: check `k3s kubectl describe pod` — usually a multi-arch image tag issue (verify `chrislusf/seaweedfs:4.44` exists for arm64).
2. **Secret not rendered / pod missing S3 config**: check `journalctl -u ab-k3s-seaweedfs-creds.service` — likely the credstore file is missing (secret not in vault, or profile not selected during packaging).
3. **No files uploaded / S3 operations fail**: verify `mc alias` works; check SeaweedFS logs: `k3s kubectl logs -l app=seaweedfs -c seaweedfs`.
4. **Data not persisting across A/B swaps**: ensure `symlink-k3s` and `data-disk` are both selected; check `/mnt/data/seaweedfs` exists and has content after reboot.
5. **Upload fails for large files**: default `-fileSizeLimitMB=256` caps object size; increase in manifest if needed.