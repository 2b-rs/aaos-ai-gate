#!/bin/bash
# Stand-in for soong_ui. Sleeps until TERM, then spends two seconds cleaning up.
set -u
log=${1:-}
if [[ -z "$log" ]]; then
  echo "fake_build: log path missing" >&2
  exit 1
fi
trap 'printf "%s\n" TERM >> "$log"; sleep 2; printf "%s\n" cleanup-done >> "$log"; exit 0' TERM
printf '%s\n' start >> "$log"
while true; do
  sleep 1
done
