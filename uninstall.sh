#!/bin/zsh
# Removes the printers that use this driver, then the driver itself.
#   ./uninstall.sh [--yes] [--force]
#   --yes     don't ask before removing printers
#   --force   remove the filter even if it wasn't installed by this project
set -euo pipefail
FILTER_DIR="/Library/Printers/Samsung/Filter"
FILTER_PATH="$FILTER_DIR/rastertoqpdl"
MARKER="$FILTER_DIR/.samsung-ml1860-macos"

YES=false FORCE=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --force) FORCE=true ;;
    *) echo "Usage: ./uninstall.sh [--yes] [--force]" >&2; exit 1 ;;
  esac
done

not_ours() {
  echo "The filter at $FILTER_PATH $1, so the printers using it" >&2
  echo "may belong to another setup. Nothing was removed." >&2
  echo "To remove them anyway, re-run with --force." >&2
  exit 1
}

# Find printers whose PPD uses this filter (CUPS keeps a copy of each printer's PPD).
# The copies are normally readable by everyone; use sudo only if they aren't.
QUEUES=()
for ppd in /etc/cups/ppd/*.ppd(N); do
  if [[ -r "$ppd" ]]; then
    grep -qF "$FILTER_PATH" "$ppd" || continue
  else
    sudo grep -qF "$FILTER_PATH" "$ppd" || continue
  fi
  QUEUES+=("${${ppd:t}%.ppd}")
done

# Only remove things this project installed, unless told otherwise.
if ! $FORCE; then
  if [[ -e "$FILTER_PATH" ]]; then
    if [[ ! -f "$MARKER" || "$(cat "$MARKER")" != "$(shasum -a 256 "$FILTER_PATH" | awk '{print $1}')" ]]; then
      not_ours "wasn't installed by this project (or was changed since)"
    fi
  elif (( ${#QUEUES} )) && [[ ! -f "$MARKER" ]]; then
    # Filter already gone and no marker: can't tell whose these printers are.
    not_ours "is missing and there's no sign this project installed it"
  fi
fi

if (( ${#QUEUES} )); then
  echo "These printers use this driver and will be removed:"
  printf '  %s\n' "${QUEUES[@]}"
  if ! $YES; then
    read -q "?Remove them? [y/N] " || { echo; echo "Nothing was removed."; exit 1; }
    echo
  fi
  for q in "${QUEUES[@]}"; do
    sudo lpadmin -x "$q"
    echo "Removed printer $q."
  done
else
  echo "No printers use this driver."
fi

if [[ -e "$FILTER_PATH" || -e "$MARKER" ]]; then
  sudo rm -f "$FILTER_PATH" "$MARKER"
  echo "Removed filter."
fi
# Remove the folders only if empty (other Samsung drivers may live there).
for d in "$FILTER_DIR" /Library/Printers/Samsung; do
  if [[ -d "$d" ]]; then
    sudo rmdir "$d" 2>/dev/null || echo "Left $d in place (not empty)."
  fi
done

# Make sure debug logging isn't left on from test-print.sh --debug.
# (Only if it's on: cupsctl rewrites cupsd.conf and restarts the print system.)
SETTINGS=$(cupsctl)
if [[ "$SETTINGS" == *_debug_logging=1* ]]; then
  sudo cupsctl --no-debug-logging
  echo "Turned CUPS debug logging off."
fi
echo "Done."
echo "Left in place: the build/ folder (rm -rf build) and Homebrew's jbigkit"
echo "(brew uninstall jbigkit, if nothing else of yours uses it)."
