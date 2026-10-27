#!/bin/zsh
# Sends a one-page test print and shows the queue status.
#   ./test-print.sh [--debug] [QUEUE]
# QUEUE defaults to the printer added by install.sh (Samsung_ML_1860/1865/1670).
# --debug turns on detailed CUPS logging for this job, shows the logs, then restores the setting.
# Note: debug logs record usernames, job titles and file names (not page contents)
# in /var/log/cups/error_log, which other users on this Mac can read.
set -euo pipefail
LOG=/var/log/cups/error_log
DEBUG=false QUEUE=""
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=true ;;
    -*) echo "Usage: ./test-print.sh [--debug] [QUEUE]" >&2; exit 1 ;;
    *) QUEUE="$arg" ;;
  esac
done

if [[ -z "$QUEUE" ]]; then
  QUEUE=$(lpstat -e 2>/dev/null | grep -E '^Samsung_ML_(1860|1865|1670)$' | head -1 || true)
  [[ -n "$QUEUE" ]] || { echo "No printer from install.sh found. Run ./install.sh first." >&2; exit 1; }
fi
echo "Printing a test page on $QUEUE..."

if $DEBUG; then
  # Only switch debug logging if it's off, and only switch it back if we turned it on.
  # (cupsctl rewrites cupsd.conf and restarts the print system.)
  SETTINGS=$(cupsctl)
  if [[ "$SETTINGS" == *_debug_logging=1* ]]; then
    echo "CUPS debug logging is already on."
  else
    echo "Turning on CUPS debug logging..."
    sudo cupsctl --debug-logging
    trap 'echo "Turning debug logging off..."; sudo cupsctl --no-debug-logging' EXIT
  fi
  START=$(date '+%Y-%m-%d %H:%M:%S')
fi

printf 'Samsung ML-1860 series test page\n\nPrinted from macOS via SpliX.\n%s\n' "$(date)" \
  | lp -d "$QUEUE" -t "Test page"

# Wait up to 60s for the job to leave the queue.
for n in {1..30}; do
  [[ -z "$(lpstat -o "$QUEUE" 2>/dev/null)" ]] && break
  sleep 2
done
lpstat -p "$QUEUE"
if [[ -n "$(lpstat -o "$QUEUE" 2>/dev/null)" ]]; then
  echo "Job still queued:"; lpstat -o "$QUEUE"
fi

if $DEBUG; then
  echo
  echo "=== CUPS log (SpliX and errors) ==="
  if [[ ! -e "$LOG" ]]; then
    echo "(no CUPS error_log yet)"
  else
    { grep -a -E "SpliX|rastertoqpdl|cgpdftoraster|\[Job [0-9]+\] (E|W) " "$LOG" || true; } \
      | tail -40 | grep . || echo "(no matching lines)"
  fi
  echo
  echo "=== Sandbox denials for print filters since $START ==="
  { log show --start "$START" --style compact \
      --predicate 'sender == "Sandbox" AND (eventMessage CONTAINS "rastertoqpdl" OR eventMessage CONTAINS "cgpdftoraster" OR eventMessage CONTAINS "cgtexttopdf" OR eventMessage CONTAINS "usb(")' \
      2>/dev/null || true; } | grep -i "deny" | tail -20 || echo "(none)"
else
  echo "If nothing printed, run:  ./test-print.sh --debug"
fi
