# Cloud VM deployment (OCI ARM and similar)

This document covers the specific considerations for running the A/B image
stack on a cloud-hosted VM, using Oracle OCI Ampere A1 as the reference
platform. The constraints are different from baremetal: no physical console,
no USB keyboard, no ability to type at boot unless you use the cloud serial
console.

## What works without modification

* **A/B root layout** — OCI block volumes are plain GPT disks. ESP + two root
  slots + optional home partition work normally.
* **Secure Boot** — already disabled in `hosts/cloudbox/secure-boot.disabled`.
  OCI Shielded Instances have their own Measured Boot chain; the custom key
  flow used for baremetal does not apply.
* **ARM64 builds** — the `cloudbox` host overlay forces `Architecture=arm64`
  and uses `linux-image-arm64`.
* **Ansible-driven updates** — `ansible/playbooks/cloudbox-ab-deploy.yml`
  supports both bootstrap and in-place update modes.

## LUKS encryption on a headless cloud VM

The build always prompts for a LUKS passphrase. For non-interactive use (e.g.
in Ansible), set `LUKS_PASSPHRASE` before running `build.sh`:

```sh
export LUKS_PASSPHRASE="your-passphrase"
./build.sh --host cloudbox
```

The Ansible playbook can inject this variable:

```yaml
environment:
  LUKS_PASSPHRASE: "{{ cloudbox_luks_passphrase }}"
```

Store `cloudbox_luks_passphrase` in Ansible Vault, not in plaintext inventory.

### First boot — entering the passphrase

After the image is deployed and the VM boots, it will pause at the LUKS
prompt. On OCI, use the **serial console** to type the passphrase:

1. Open the OCI console → Compute → your instance → Serial Console
2. Connect via the cloud shell or SSH-based serial console link
3. Type the LUKS passphrase when the prompt appears

### After first boot — TPM auto-unlock

OCI Shielded Instances expose a virtual TPM (vTPM). After the first
passphrase-unlocked boot, bind LUKS to the vTPM so subsequent boots
auto-unlock:

```sh
sudo ab-enroll-tpm
```

This makes the instance fully headless for future boots. The passphrase
remains as a manual fallback (accessible via serial console if needed).

**Note:** If the instance is not a Shielded Instance, vTPM is not available.
In that case, you have two options:
1. Disable LUKS entirely by setting `Encrypt=no` in the host's mkosi config.
   Credentials in `/etc/credstore/` will not be at-rest encrypted; rely on
   OCI IAM and your Tailscale/SSH key chain instead.
2. Implement network-bound disk encryption (NBDE) via Clevis + Tang — more
   complex but provides at-rest encryption without manual passphrase entry.

## Initial bootstrap workflow

Unlike baremetal (boot from USB → run installer), cloud bootstrap requires a
running system to write the first image. The recommended path:

### Option A: Ansible bootstrap mode (recommended)

1. Provision a stock Debian ARM64 instance on OCI using the standard OCI
   console. This is a temporary system — it will be replaced.
2. **Attach a second block volume** to the instance. This becomes the target
   for the A/B image.
3. Clone this repo onto the temporary instance.
4. Run the Ansible playbook in bootstrap mode from your local machine:
   ```sh
   ansible-playbook ansible/playbooks/cloudbox-ab-deploy.yml \
     -e cloudbox_bootstrap_target=/dev/sdb \
     -e cloudbox_luks_passphrase=<passphrase>
   ```
   This builds the image on the instance and writes it to `/dev/sdb`.
5. In the OCI console, swap the boot volume: detach `/dev/sdb` and reattach
   it as the primary boot volume. Delete the old boot volume.
6. Start the instance. Enter the LUKS passphrase via serial console on first
   boot. Run `ab-enroll-tpm` to enable auto-unlock on a Shielded Instance.

### Option B: OCI custom image import

1. Build the image locally on an ARM64 machine:
   ```sh
   ./build.sh --host cloudbox
   ```
2. Export `mkosi.output/deb-ab_<VERSION>_arm64.root.raw` to OCI Object Storage.
3. Import it as a custom OCI image (Compute → Custom Images → Import).
4. Create an instance from the custom image.

This path bypasses the interactive LUKS passphrase at build time — the
encrypted root is already in the `.raw` — but you still need to unlock it
via serial console on first boot unless vTPM enrollment was done before
export.

## Known limitations

* **No in-place A/B update on the running boot volume** — you cannot swap the
  running root for an A/B update while the VM is live on that volume. Instead
  use Ansible update mode (`cloudbox_bootstrap_target` unset), which uses
  `sysupdate-local-update.sh` to stage the next version in the idle A/B slot
  and reboots into it.
* **No hibernation** — cloud block volumes are not a good fit for suspend/resume
  with encrypted swap; hibernation is not configured in this layout.
* **Serial console latency** — the OCI serial console can be slow. If the LUKS
  timeout is short, the system may fall back to emergency mode before the
  passphrase can be typed. The cloudbox kernel args set a longer timeout.
