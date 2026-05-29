# Documentation index

| Document | What it covers |
| --- | --- |
| [security-model.md](security-model.md) | Full trust chain: Secure Boot, LUKS, identity generation, package trust, what is committed vs. generated |
| [credential-encryption.md](credential-encryption.md) | Three-layer secret protection (age vault → LUKS → systemd LoadCredential=) with a build-to-runtime diagram |
| [user-provisioning.md](user-provisioning.md) | Defining users in the secrets file, password hashing, dotfiles bootstrap, UID/GID sync, first-boot service |
| [local-secret-vault.md](local-secret-vault.md) | age-encrypted vault: day-zero setup, schema, edit and build workflows |
| [ab-workflow.md](ab-workflow.md) | A/B retained-root flow, dual-boot preserve mode, persistent container storage symlinks |
| [remote-access.md](remote-access.md) | Tailscale (primary) + Cloudflare Tunnel (backup) + FIDO2 SSH keys; setup, connection, and rotation |
| [secure-boot.md](secure-boot.md) | Secure Boot key generation and per-host enrollment |
| [secure-boot-roadmap.md](secure-boot-roadmap.md) | Planned Secure Boot enhancements |
| [home-storage.md](home-storage.md) | Persistent /home and DATA partition strategies |
| [live-test-usb.md](live-test-usb.md) | Hardware-test USB creation, boot, and install-to-disk flow |
| [live-usb-verification.md](live-usb-verification.md) | Verifying a USB write before booting |
| [qemu-smoke-testing.md](qemu-smoke-testing.md) | QEMU boot diagnostics (nspawn mode, debug flags, serial console) |
| [hardening-walkthrough.md](hardening-walkthrough.md) | System hardening steps applied to built images |
| [alerting.md](alerting.md) | Health-check hooks and notification integrations |
| [runbook.md](runbook.md) | Operational runbook for bootstrapped machines |
| [ab-systemd-boot-deploy.md](ab-systemd-boot-deploy.md) | systemd-boot A/B setup details |
| [cloud-vm.md](cloud-vm.md) | Cloud VM deployment (OCI ARM): LUKS passphrase handling, serial console unlock, vTPM auto-unlock, bootstrap workflow |
| [ab-grub-deploy.md](ab-grub-deploy.md) | Legacy GRUB path (deprecated; kept for reference) |
