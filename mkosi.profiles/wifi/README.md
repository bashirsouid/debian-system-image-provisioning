# wifi

NetworkManager + iwd for Wi-Fi. Ships common non-free Wi-Fi firmware (Intel
iwlwifi, Realtek, Mediatek). If `wifi-ssid` and `wifi-psk` secrets are present,
pre-seeds a NetworkManager connection so the machine joins the configured
network on first boot without manual setup.

## Optional secrets

| Secret | Vault key | Notes |
| --- | --- | --- |
| `wifi-ssid` | `"wifi-ssid"` | SSID to pre-seed (optional) |
| `wifi-psk` | `"wifi-psk"` | WPA passphrase (optional) |

Both secrets must be present to pre-seed a connection. If either is absent,
NetworkManager starts without a pre-configured network; you can connect
interactively with `nmtui` or `nmcli`.

## Notes

* The pre-seeded connection is created with `autoconnect=yes` so the machine
  reconnects automatically after reboots.
* Hardware requiring firmware not covered by this profile may need a host
  overlay to add the specific package.
