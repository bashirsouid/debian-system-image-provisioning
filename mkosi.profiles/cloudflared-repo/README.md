# cloudflared-repo

Repo-only base profile for Cloudflare's apt repository. Ships the
`cloudflared.sources` source, the `cloudflare-main.gpg` signing key, and the
`apt-keys.conf` that `fetch-third-party-keys.sh` uses to fetch/pin the key. No
packages.

You don't select it directly: profiles that install the `cloudflared` package
declare `requires=cloudflared-repo` and the resolver pulls it in once. Current
consumers:

- `cloudflare-tunnel` — outbound-only tunnel connector (`cloudflared` daemon).
- `ssh-client-cloudbox-profile` — SSH `ProxyCommand` through cloudflared.

> Do not add a bare `Packages=` here — an empty list assignment resets mkosi's
> whole package list.

No secret values are required (the tunnel token secret is used by
`cloudflare-tunnel`, not by this repo base).
