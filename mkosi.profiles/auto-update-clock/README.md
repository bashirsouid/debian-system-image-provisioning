# auto-update-clock

Runs the clock repair script once during boot after `network-online.target` has
completed and the network has had five seconds to stabilize. The service runs
the script in unattended mode (`--yes`) so it can install its optional tools
if needed and finish without an interactive prompt.

