# Ansible cloudbox A/B deploy path

This directory contains an opinionated playbook for the ARM64 `cloudbox`
scenario.

What it does:
- installs build/deploy prerequisites on the target host
- copies the current repository tree to the target host
- renders `.users.json` from Ansible variables
- renders `ab-flash.conf` for the target host
- builds the image on the **ARM host itself** with `--profile server --host cloudbox`
- deploys the image to the inactive A/B slot
- reboots the host
- reads `ab-status` after the reboot
- can optionally run `ab-bless-boot` after the post-reboot validation step

## Why the image is built on the ARM host

That is the simplest reliable path for early testing. It avoids cross-architecture
build surprises and matches the real hardware/firmware/kernel/userspace mix on
the machine that will actually boot the image.

## Usage

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
cp ansible/group_vars/cloudbox.yml.example ansible/group_vars/cloudbox.yml
# edit the inventory and variables
ansible-playbook -i ansible/inventory.ini ansible/playbooks/cloudbox-ab-deploy.yml
```

## Important variables

- `cloudbox_users`
- `cloudbox_esp_part`
- `cloudbox_slot_a_root`
- `cloudbox_slot_b_root`
- `cloudbox_extra_kernel_args`
- `cloudbox_auto_bless`
- `cloudbox_reboot_on_health_failure`
- `cloudbox_bless_after_health`

## Expected policy defaults

The sample group vars default to a server-style policy:
- auto bless enabled
- reboot on health failure enabled
- serial console enabled through `console=ttyAMA0,115200 console=tty1`
