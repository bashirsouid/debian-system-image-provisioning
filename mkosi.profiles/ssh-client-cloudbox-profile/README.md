# ssh-client-cloudbox-profile

SSH client configuration for Cloudflare Tunnel access. Adds a system-wide SSH client config that routes SSH connections through `cloudflared access ssh`.

## What this profile provides

* `/etc/ssh/ssh_config.d/99-cloudflare-ssh.conf` — ProxyCommand configuration for SSH hostnames served via Cloudflare Tunnel
* Installs `cloudflared` package (required for the ProxyCommand)

## Usage

Edit the config file to set your tunnel hostname:

```bash
# In mkosi.profiles/ssh-client-cloudbox-profile/mkosi.extra/etc/ssh/ssh_config.d/99-cloudflare-ssh.conf
Host ssh.yourdomain.com
    ProxyCommand /usr/bin/cloudflared access ssh --hostname %h
```

Then SSH to your host:

```bash
ssh user@ssh.yourdomain.com
```

## Secrets

This profile does not require any build-time secrets. The `cloudflared access ssh` command handles authentication via browser-based Cloudflare Access at SSH connection time.

## Building the client image

```bash
sudo mkosi --profile ssh-client-cloudbox-profile build
```

Or with the role:

```bash
./build.sh --profile ssh-client-cloudbox [other options]
```