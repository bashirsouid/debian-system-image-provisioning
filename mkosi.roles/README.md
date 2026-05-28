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
| backup | Periodic backups using kopia |
| group_dev | General-purpose developer workstation with dev tools, VS Code, Incus, and K3s |
| group_game | Gaming setup with Flatpak and Steam |
| group_photo | Photo workstation with Digikam editor and related tools |
| symlinks | Storage symlink profiles for easy composition (Docker, K3s) |

