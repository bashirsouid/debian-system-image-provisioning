# k3s-hello-world

Sample **static site** deployed entirely via k3s auto-deploy manifests.
No build-time dependencies beyond the multi-arch container image
(`nginx:stable-alpine`, pulled at runtime from Docker Hub).

## What ships in this profile

| Path | Purpose |
| --- | --- |
| `mkosi.extra/var/lib/rancher/k3s/server/manifests/hello-world.yaml` | Multi-doc YAML: ConfigMap (index.html), Deployment (nginx, port 80), Service (NodePort 30080). k3s applies this on startup. |
| `profile.manifest` | `requires="k3s k3s-proxy"` — pulls both transitively. |

## How it works

1. Image build bakes the manifest into `/var/lib/rancher/k3s/server/manifests/hello-world.yaml`.
2. At first boot, `symlink-k3s` (if selected) adopts the baked manifest into `/mnt/data/k3s/server/manifests/` **before** k3s starts.
3. `k3s-install.service` installs k3s with Traefik/ServiceLB disabled (via `k3s-proxy`'s `/etc/default/ab-k3s-extra`).
4. k3s starts, auto-applies the manifest → Deployment + NodePort Service 30080 comes up.
5. Host Caddy (`k3s-proxy`) terminates TLS on 443 and reverse-proxies `127.0.0.1:30080`.

## Dependencies

| Profile | Why |
| --- | --- |
| `k3s` | The cluster runtime. |
| `k3s-proxy` | Host Caddy doing public TLS + disabling k3s' bundled Traefik/ServiceLB. |

## Architecture

- `nginx:stable-alpine` is a multi-arch image (amd64 + arm64) — works on cloudbox (arm64) and any amd64 host.
- No architecture pinning in this profile.

## Verify after boot

```bash
# k3s pods
k3s kubectl get pods -A

# Service shows NodePort 30080
k3s kubectl get svc -A | grep hello-world

# Caddy reachable on 80 (placeholder) or 443 (with k3s_proxy_domain)
curl -I http://<host-ip>
curl -I https://<your-domain>
```

## Notes

- The ConfigMap embeds a simple HTML page. Swap it by editing the manifest in the profile and rebuilding.
- No Ingress resource is created — Caddy **is** the ingress layer.
- Cert persistence across A/B swaps requires the `symlink-caddy` profile (see its README).