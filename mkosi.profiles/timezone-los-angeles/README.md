# timezone-los-angeles

This profile configures timezone-los-angeles related settings for mkosi.

## Features

- Sets timezone to America/Los_Angeles
- Includes a systemd timer (`sync-clock.timer`) that synchronizes the system clock with the RTC when the network becomes available
  - Runs 5 seconds after boot
  - Runs every hour thereafter to keep clocks in sync
  - Only activates when network is online

No secret values are required unless otherwise documented.
