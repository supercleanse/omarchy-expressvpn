#!/usr/bin/env bash
# A stand-in for expressvpnctl, for developing the widget without touching the
# real daemon. It never connects, disconnects, logs in or out, or changes a
# setting: every write command fails with "fake ctl: refusing ...".
#
# Point the widget at it with the dev-only `ctlPath` setting on the bar entry
# in ~/.config/omarchy/shell.json:
#
#   { "id": "supercleanse.expressvpn", "ctlPath": "/path/to/dev/fake-expressvpnctl.sh" }
#
# Pick the state to simulate with $SUPERCLEANSE_EXPRESSVPN_FAKE_MODE or by
# writing it to $XDG_RUNTIME_DIR/supercleanse-expressvpn-fake-mode:
#
#   connected | disconnected | connecting | interrupted | logout | down
#
# "down" behaves like an unreachable daemon: one-shot commands time out with
# exit 2 and `monitor` hangs. The IPs are RFC 5737 documentation addresses.
set -u

mode_file="${XDG_RUNTIME_DIR:-/tmp}/supercleanse-expressvpn-fake-mode"
mode=${SUPERCLEANSE_EXPRESSVPN_FAKE_MODE:-$(cat "$mode_file" 2>/dev/null || echo disconnected)}
[[ ${1:-} == -t ]] && shift 2
cmd="${1:-} ${2:-}"

case ${1:-} in
  connect | disconnect | login | logout | set | background | resetsettings)
    echo "fake ctl: refusing $1" >&2
    exit 1 ;;
esac

regions() {
  printf '%s\n' smart albania argentina australia-sydney australia-melbourne austria \
    belgium brazil canada-toronto canada-vancouver denmark finland france-paris-1 \
    germany-frankfurt-1 germany-berlin hong-kong-2 india-\(via-uk\) ireland italy-milan \
    japan-tokyo mexico netherlands-amsterdam new-zealand norway poland portugal \
    singapore-marina-bay south-korea-2 spain-madrid sweden switzerland uk-london \
    usa-chicago usa-los-angeles-1 usa-miami usa-new-york usa-san-francisco usa-seattle
}

if [[ $mode == down ]]; then
  [[ ${1:-} == monitor ]] && exec sleep infinity
  sleep 1
  echo "Timed out after 1 sec" >&2
  exit 2
fi

case $mode in
  connected) state=Connected ;;
  connecting) state=Connecting ;;
  interrupted) state=Interrupted ;;
  *) state=Disconnected ;;
esac
region=usa-new-york
# Like the real client, pubip keeps reporting the pre-VPN (home) address even
# while connected; vpnip is the tunnel address.
pubip=198.51.100.23
vpnip=Unknown
[[ $state == Connected ]] && vpnip=203.0.113.58

case $cmd in
  "status "*)
    if [[ $mode == logout ]]; then
      echo "Not logged in."
    elif [[ $state == Connected ]]; then
      # The real format: no Location line, the region rides on line one.
      printf 'Connected to %s\n\nProtocol in use: LightwayUdp\nNetwork Lock: enabled when connected\nSplit Tunnel: disabled\n' "$region"
    else
      printf '%s\n\nLocation: %s\nNetwork Lock: enabled when connected\nSplit Tunnel: disabled\n' "$state" "$region"
    fi ;;
  "monitor connectionstate") echo "$state"; exec sleep infinity ;;
  "monitor "*) echo Unknown; exec sleep infinity ;;
  "get connectionstate") echo "$state" ;;
  "get regions") regions ;;
  "get region") echo "$region" ;;
  "get smart") echo usa-chicago ;;
  "get pubip") echo "$pubip" ;;
  "get vpnip") echo "$vpnip" ;;
  "get networklock") echo false ;;
  "get autoconnect") echo false ;;
  *) echo "Unknown type: ${2:-}" >&2; exit 1 ;;
esac
exit 0
