# Ansible cloudbox native deploy path

This directory contains an opinionated ARM64 `cloudbox` playbook for the **native** retained-version
workflow:

- build with `mkosi` on the ARM host itself
- bootstrap once with `systemd-repart` + `systemd-sysupdate`
- update later with `systemd-sysupdate`
- reboot into the new trial version
- read boot/health status with `ab-status`

## Why the image is built on the ARM host

That is the simplest reliable early-test path. It avoids cross-architecture surprises and matches
what the target firmware, kernel, and userspace will actually boot.

## Two operating modes

### 1. Bootstrap mode

Set `cloudbox_bootstrap_target` to a **blank or offline** disk or raw disk image.

The playbook will then:

- build the image on the ARM target
- export versioned sysupdate artifacts
- destructively repartition the target with `systemd-repart`
- install `systemd-boot`
- seed the first system version with `systemd-sysupdate`

This is for the **first install only**.

### 2. Update mode

Leave `cloudbox_bootstrap_target` empty.

The playbook will then:

- build a new version on the ARM target
- stage it with `systemd-sysupdate`
- reboot into the new trial version
- show `ab-status` after the system comes back

This is the normal path after the host is already running the native layout.

## Important limitation

The bootstrap playbook does **not** magically replace the currently running root disk in place.
It prepares a target disk or raw image. On cloud platforms, the final “boot from that new disk” step
is still platform-specific.

That limitation is about the **first** install only.
Once the machine is already running the native retained-version layout, later updates are handled
in place by `systemd-sysupdate` and the boot loader.

## Usage

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
cp ansible/group_vars/cloudbox.yml.example ansible/group_vars/cloudbox.yml
# edit the inventory and variables
ansible-playbook -i ansible/inventory.ini ansible/playbooks/cloudbox-ab-deploy.yml
```

## Main variables

- `cloudbox_users`
- `cloudbox_extra_kernel_args`
- `cloudbox_bootstrap_target`
- `cloudbox_loader_timeout`
- `cloudbox_esp_size`
- `cloudbox_root_slot_size`
- `cloudbox_update_reboot`
- `cloudbox_bless_after_reboot`
