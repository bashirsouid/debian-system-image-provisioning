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
| `wifi-band` | `"wifi-band"` | Band pin for the seeded connection: `a` (5 GHz, allows 6 GHz on NM ≥ 1.58), `b`/`bg` (2.4 GHz), or `6GHz` (literal 6 GHz, needs NM ≥ 1.58). Per-host override via `hosts.<hostname>.wifi-band`. |
| `wifi-powersave-off` | `"wifi-powersave-off"` | `true` to disable Wi-Fi power saving (emits `wifi.powersave=2` conf.d drop-in); `false`/absent leaves NM default. Independent of ssid/psk presence. |

Both `wifi-ssid` and `wifi-psk` must be present to pre-seed a connection. If either is absent,
NetworkManager starts without a pre-configured network; you can connect
interactively with `nmtui` or `nmcli`.

## Notes

* The pre-seeded connection is created with `autoconnect=yes` so the machine
  reconnects automatically after reboots.
* When `wifi-band` is set, the connection will **not fall back to 2.4 GHz** — if the 5/6 GHz radios are out of range, the device will not connect. This is intentional for laptops used near the gateway.
* This profile uses NM with the **iwd backend** (`wifi.backend=iwd`). The `band=` pin has been empirically validated on this stack (Trixie NM 1.52 + iwd): setting `band=a` caused association to a 6 GHz BSSID (6935 MHz, 160 MHz width). NM ≥ 1.58 adds a literal `6GHz` band value; on older NM, `a` already permits 6 GHz association.
* Site-scoped, not device-scoped: a global `wifi-band` in the vault pins every provisioned device joining that SSID. Per-host override via `hosts.<hostname>.wifi-band` handles exceptions.
* If you later split the gateway bands into separate SSIDs, these settings become harmless dead weight — no migration needed.
* Hardware requiring firmware not covered by this profile may need a host
  overlay to add the specific package.
