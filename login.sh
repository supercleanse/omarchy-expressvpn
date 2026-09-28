#!/usr/bin/env bash
# Log in to ExpressVPN with an activation code read from stdin.
# Usage: login.sh [path-to-expressvpnctl] <<< CODE
#
# expressvpnctl only accepts credentials from a file, so the code goes into a
# private temp file under $XDG_RUNTIME_DIR (a per-user tmpfs, mode 600) and
# the file is removed the moment `login` returns, or on any signal. The code
# never appears on a command line, in the environment, or in a log.
set -u
umask 077

ctl=${1:-${SUPERCLEANSE_EXPRESSVPN_CTL:-/usr/bin/expressvpnctl}}
dir=${XDG_RUNTIME_DIR:-}
if [[ -z $dir || ! -d $dir || ! -w $dir ]]; then
  echo "XDG_RUNTIME_DIR is not available" >&2
  exit 3
fi

IFS= read -r code || true
code=${code//[[:space:]]/}
if [[ -z $code ]]; then
  echo "No activation code given" >&2
  exit 4
fi

file=$(mktemp "$dir/supercleanse-expressvpn-login.XXXXXXXX") || { echo "Could not create a temp file" >&2; exit 3; }
trap 'rm -f -- "$file"' EXIT
trap 'exit 130' INT TERM HUP
chmod 600 -- "$file"
printf '%s\n' "$code" > "$file"
unset code

"$ctl" -t 30 login "$file"
