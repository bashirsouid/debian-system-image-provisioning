#!/usr/bin/env bash
# fix-trixie-clock.sh v2 - bulletproof clock sync for Debian 13 (trixie)
#
# Gets the current time from the internet, trying methods in order and
# stopping at the first one that works:
#   A. Repair systemd-timesyncd and wait for sync
#   B. One-shot clock step with ntpdate
#   C. Offer to install chrony as a working permanent sync daemon
#   D. Last resort: read the Date: header of an HTTPS response
#
# Afterwards, writes the corrected time to the RTC and verifies the result.
# Use -y/--yes for unattended operation.

set -u

ASSUME_YES=0
case "${1:-}" in -y|--yes) ASSUME_YES=1 ;; esac

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
err()  { printf '  [x]  %s\n' "$*" >&2; }

confirm() {
  (( ASSUME_YES )) && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

APT_UPDATED=0
apt_install() {
  (( APT_UPDATED )) || { apt-get update -qq && APT_UPDATED=1; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
}
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
ensure_pkg() {
  if pkg_installed "$1"; then ok "$2 already installed ($1)"; return 0; fi
  warn "$2 missing (package: $1)"
  if confirm "Install $1?"; then
    apt_install "$1" && { ok "installed $1"; return 0; }
    err "failed to install $1"
  else
    warn "skipped $1"
  fi
  return 1
}

http_epoch() {
  local url hdr
  for url in https://www.google.com https://www.cloudflare.com https://www.microsoft.com; do
    hdr=""
    if command -v curl >/dev/null 2>&1; then
      hdr=$(curl -fsSI --max-time 8 "$url" 2>/dev/null | tr -d '\r' | grep -i '^date:' | head -n1 | cut -d' ' -f2-)
    elif command -v wget >/dev/null 2>&1; then
      hdr=$(wget -qS --spider --timeout=8 "$url" 2>&1 | tr -d '\r' | grep -i '^[[:space:]]*date:' | head -n1 | sed 's/^[^:]*: *//')
    else
      return 1
    fi
    if [[ -n "$hdr" ]]; then
      date -u -d "$hdr" +%s 2>/dev/null && return 0
    fi
  done
  return 1
}

synced() { timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; }

fix_netif_state() {
  if ! systemctl is-active --quiet systemd-networkd 2>/dev/null && [[ -d /run/systemd/netif ]]; then
    warn "systemd-networkd is not running but stale /run/systemd/netif exists"
    rm -rf /run/systemd/netif
    ok "cleared stale networkd state"
  fi
}
try_timesyncd() {
  pkg_installed systemd-timesyncd || return 1
  timedatectl set-ntp true >/dev/null 2>&1
  systemctl restart systemd-timesyncd
  local i
  for i in $(seq 1 12); do
    sleep 5
    synced && return 0
  done
  return 1
}
try_ntpdate() {
  command -v ntpdate >/dev/null 2>&1 || return 1
  systemctl stop systemd-timesyncd 2>/dev/null
  local s
  for s in time.cloudflare.com time.google.com 0.debian.pool.ntp.org pool.ntp.org; do
    if ntpdate -b -u -t 5 "$s" >/dev/null 2>&1; then
      ok "clock stepped via ntpdate ($s)"
      systemctl start systemd-timesyncd 2>/dev/null
      return 0
    fi
  done
  systemctl start systemd-timesyncd 2>/dev/null
  return 1
}
try_chrony() {
  if ! pkg_installed chrony; then
    confirm "timesyncd is not cooperating - install chrony as the sync daemon?" || return 1
    apt_install chrony || { err "chrony install failed"; return 1; }
  fi
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1
  systemctl enable --now chrony >/dev/null 2>&1 || return 1
  chronyc -a 'burst 4/4' >/dev/null 2>&1 || true
  sleep 8
  chronyc -a makestep >/dev/null 2>&1 || true
  local i
  for i in 1 2 3; do
    : "$i"
    sleep 5
    chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && return 0
  done
  return 1
}
try_http() {
  local ep
  ep=$(http_epoch) || return 1
  date -s "@$ep" >/dev/null || return 1
  ok "clock set from HTTPS Date: header (epoch $ep)"
  return 0
}
verify() {
  local ep now d
  ep=$(http_epoch) || { warn "could not verify against network time"; return 0; }
  now=$(date +%s); d=$(( now - ep )); (( d < 0 )) && d=$(( -d ))
  if (( d <= 5 )); then
    ok "verified: system clock within ${d}s of network time"
    return 0
  fi
  warn "clock still ${d}s off network time"
  return 1
}

say "1/5 Dependencies"
ensure_pkg util-linux-extra "hwclock (RTC tool)"
HAVE_HWCLOCK=$?
ensure_pkg ntpsec-ntpdate "ntpdate (one-shot NTP)"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  ensure_pkg curl "curl (HTTPS fallback)" || true
fi

say "2/5 Environment repair"
fix_netif_state

say "3/5 Sync clock from the internet"
SYNCED_VIA=""
if synced; then
  ok "already synchronized"
  SYNCED_VIA=timesyncd
elif try_timesyncd; then
  SYNCED_VIA=timesyncd
elif { warn "timesyncd failed, trying ntpdate..."; try_ntpdate; }; then
  SYNCED_VIA=ntpdate
elif { warn "ntpdate failed, trying chrony..."; try_chrony; }; then
  SYNCED_VIA=chrony
elif { warn "chrony failed, trying HTTPS header..."; try_http; }; then
  SYNCED_VIA=http
fi
[[ -n $SYNCED_VIA ]] && ok "time synchronized via: $SYNCED_VIA"

say "4/5 Hardware clock"
if [[ -n $SYNCED_VIA && $HAVE_HWCLOCK -eq 0 ]]; then
  hwclock --systohc && ok "RTC written from corrected system clock"
  if timedatectl | grep -q 'RTC in local TZ: yes'; then
    warn "RTC in local TZ is set; with the Windows UTC fix applied you want:"
    warn "  timedatectl set-local-rtc 0 --adjust-system-clock"
  fi
elif [[ -z $SYNCED_VIA ]]; then
  warn "not touching the RTC - system clock was not confirmed correct"
else
  warn "hwclock unavailable; RTC not written"
fi

say "5/5 Result"
timedatectl
echo
if [[ -n $SYNCED_VIA ]]; then
  verify
  case $SYNCED_VIA in
    timesyncd|chrony) ok "a background daemon will keep the clock in sync" ;;
    *) warn "clock is correct now, but no working daemon keeps it that way" ;;
  esac
else
  err "all methods failed - check the internet connection"
  exit 1
fi
