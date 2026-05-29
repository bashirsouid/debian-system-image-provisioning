# MKOSI Roles

Expanded by build.sh into the profile list below. One-level-only: a
role file can only list atomic profiles (each must have
`mkosi.profiles/<name>/`), never another role.

Edit freely. Keep one profile per line (# for comments) or put them
space-separated on one line — build.sh strips comments and collapses
whitespace.

## Roles

| Role | Description |
|------|-------------|
| `server-stack` | Production headless server baseline: `server + ssh-server + tailscale + cloudflare-tunnel + healthchecksio` |
| `desktop` | Base graphical workstation layer: AwesomeWM + audio + Bluetooth + dev-tools + ssh-server + wifi. Pair with `devbox` or `macbook` as the kernel base. |
| `backup` | Periodic backups using kopia |
| `group_dev` | Heavy developer tooling: VS Code, Incus containers, K3s — compose on top of `desktop` |
| `group_game` | Gaming setup with Flatpak and Steam |
| `group_photo` | Photo workstation with Digikam editor |
| `symlinks` | Storage symlink profiles for persistent Docker/K3s data across A/B updates |

## Common compositions

```sh
# Remotely managed production server (full stack)
./build.sh --profile server-stack --host myserver

# Workstation with Liquorix kernel + full desktop
./build.sh --profile "devbox desktop" --host mymachine

# Full developer workstation with heavy tooling
./build.sh --profile "devbox desktop group_dev" --host mymachine

# Add backups to any of the above
./build.sh --profile "server backup" --host myserver
```

