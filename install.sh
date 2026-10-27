#!/bin/zsh
# Installs the SpliX driver and adds a Samsung ML-1860 series printer connected by USB.
# Run ./build.sh first, then:  ./install.sh --model ML-1865 [--paper A4|Letter]
# To update later, just run ./install.sh: it keeps your model and paper size.
# If anything fails, or you press Ctrl-C, the previous filter is put back.
set -euo pipefail
cd "${0:A:h}"

FILTER_DIR="/Library/Printers/Samsung/Filter"
FILTER="rastertoqpdl"
# Records the checksum of the filter this project installed, so we never
# silently replace a SpliX filter installed some other way.
MARKER="$FILTER_DIR/.samsung-ml1860-macos"
BUILD="build"
QUEUE_PATTERN='^Samsung_ML_(1860|1865|1670)$'

usage() {
  cat <<EOF
Usage: ./install.sh [--model MODEL] [--paper SIZE] [--force]
  --model   ML-1860, ML-1865 or ML-1670 (the model name on your printer).
            Can be left out when updating an existing install.
  --paper   default paper size: A4 or Letter. When left out, an update keeps
            the current setting; a new install uses A4.
  --force   replace a SpliX filter that wasn't installed by this project
EOF
  exit 1
}
fail() { echo "ERROR: $*" >&2; exit 1; }

MODEL="" PAGE_SIZE="" FORCE=false
while (( $# )); do
  case "$1" in
    --model) (( $# >= 2 )) || usage; MODEL="$2"; shift 2 ;;
    --paper) (( $# >= 2 )) || usage; PAGE_SIZE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

for tool in cupsfilter cupstestppd lpadmin lpinfo lpoptions; do
  command -v "$tool" >/dev/null || fail "$tool (part of macOS's printing system) wasn't found."
done

# No --model: update the printer this project added before, if there's exactly one.
if [[ -z "$MODEL" ]]; then
  EXISTING=(${(f)"$(lpstat -e 2>/dev/null | grep -E "$QUEUE_PATTERN" || true)"})
  if (( ${#EXISTING} == 1 )); then
    MODEL="ML-${EXISTING[1]##*_}"
    echo "Updating the existing printer $EXISTING[1] ($MODEL)."
  elif (( ${#EXISTING} > 1 )); then
    echo "More than one printer from this project exists (${EXISTING[*]}); say which with --model." >&2
    usage
  else
    echo "Please say which model you have." >&2
    usage
  fi
fi
MODEL="${(U)MODEL}"
case "$MODEL" in
  ML-1860|ML-1865|ML-1670) ;;
  *) fail "$MODEL isn't supported. Supported: ML-1860, ML-1865, ML-1670." ;;
esac

PPD="ppd/${(L)MODEL//-/}.ppd"   # e.g. ppd/ml1865.ppd
QUEUE="Samsung_${MODEL//-/_}"   # e.g. Samsung_ML_1865

# No --paper: keep the existing printer's paper size, or use A4 for a new install.
if [[ -z "$PAGE_SIZE" ]]; then
  if lpstat -e 2>/dev/null | grep -qx "$QUEUE"; then
    PAGE_SIZE=$(lpoptions -p "$QUEUE" -l 2>/dev/null \
      | awk '/^PageSize\// { for (i = 2; i <= NF; i++) if ($i ~ /^\*/) { sub(/^\*/, "", $i); print $i } }')
  fi
  [[ "${(L)PAGE_SIZE}" == (a4|letter) ]] || PAGE_SIZE="A4"
fi
case "${(L)PAGE_SIZE}" in
  a4) PAGE_SIZE="A4" ;;
  letter) PAGE_SIZE="Letter" ;;
  *) fail "--paper must be A4 or Letter." ;;
esac
echo "Model: $MODEL, paper: $PAGE_SIZE"

# --- Pre-flight checks (nothing on the system is changed yet) ---
for f in "$BUILD/$FILTER" "$BUILD/$PPD" "$BUILD/SHA256SUMS"; do
  [[ -f "$f" ]] || fail "$f is missing. Run ./build.sh first."
done

# One exit handler for every way out: it undoes the filter install unless the
# install finished (NEEDS_ROLLBACK), and always removes the temporary files.
WORK=$(mktemp -d)
NEEDS_ROLLBACK=false
on_exit() {
  if $NEEDS_ROLLBACK; then rollback; fi
  rm -rf "$WORK"
}
trap on_exit EXIT
trap 'echo; exit 130' INT TERM

# Work on private copies, so the files that are checked are the files that get installed.
mkdir -p "$WORK/ppd"
cp "$BUILD/$FILTER" "$BUILD/SHA256SUMS" "$WORK/"
cp "$BUILD"/ppd/*.ppd "$WORK/ppd/"
( cd "$WORK" && shasum -a 256 -c --quiet SHA256SUMS ) \
  || fail "Build files don't match build/SHA256SUMS (changed since they were built). Re-run ./build.sh."
[[ "$(lipo -archs "$WORK/$FILTER")" == "$(uname -m)" ]] || fail "$FILTER was built for a different CPU. Re-run ./build.sh."
# Skip the filter-exists check; the filter isn't installed yet.
cupstestppd -q -I filters "$WORK/$PPD" || fail "$PPD failed validation."

# --- Check that any existing filter is ours, and keep it for rollback ---
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
BACKUP="" BACKUP_MARKER=""
if [[ -e "$FILTER_DIR/$FILTER" ]]; then
  if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$(sha "$FILTER_DIR/$FILTER")" ]]; then
    echo "Updating the filter installed earlier by this project."
  elif $FORCE; then
    echo "Replacing an existing SpliX filter (--force)."
  else
    fail "A SpliX filter is already installed at $FILTER_DIR/$FILTER, but not by this project
(or it was changed since). Replacing it would switch any printers that use it to this build.
If that's what you want, re-run with --force."
  fi
  BACKUP="$WORK/$FILTER.previous"
  cp "$FILTER_DIR/$FILTER" "$BACKUP"
  if [[ -f "$MARKER" ]]; then
    BACKUP_MARKER="$WORK/marker.previous"
    cp "$MARKER" "$BACKUP_MARKER"
  fi
fi

echo "Looking for the printer on USB..."
URI=$(sudo lpinfo --include-schemes usb -v | awk '/usb:\/\/Samsung\/ML-1860/ && !found {print $2; found=1}')
[[ -n "$URI" ]] || fail "No ML-1860 series printer found on USB. Check it's switched on and plugged in."
echo "Found: $URI"

# Stops a running offline test (it runs in the background) and its filter processes.
TEST_PID=""
stop_test() {
  if [[ -n "$TEST_PID" ]]; then
    pkill -P "$TEST_PID" 2>/dev/null || true
    kill "$TEST_PID" 2>/dev/null || true
    TEST_PID=""
  fi
}

rollback() {
  stop_test
  echo "Rolling back the filter install." >&2
  if [[ -n "$BACKUP" ]]; then
    sudo install -o root -g wheel -m 755 "$BACKUP" "$FILTER_DIR/$FILTER"
    if [[ -n "$BACKUP_MARKER" ]]; then
      sudo install -o root -g wheel -m 644 "$BACKUP_MARKER" "$MARKER"
    else
      sudo rm -f "$MARKER"
    fi
    echo "Put the previously installed filter back." >&2
  else
    sudo rm -f "$FILTER_DIR/$FILTER" "$MARKER"
    sudo rmdir "$FILTER_DIR" /Library/Printers/Samsung 2>/dev/null || true
  fi
}

# --- Install the filter ---
sudo -v   # refresh the password timeout so a later rollback doesn't stop to ask
NEEDS_ROLLBACK=true
# CUPS requires the filter and its folders to be root-owned and not writable by others.
sudo install -d -o root -g wheel -m 755 /Library/Printers/Samsung "$FILTER_DIR"
sudo install -o root -g wheel -m 755 "$WORK/$FILTER" "$FILTER_DIR/$FILTER"
sudo xattr -c "$FILTER_DIR/$FILTER"
sha "$WORK/$FILTER" > "$WORK/marker"
sudo install -o root -g wheel -m 644 "$WORK/marker" "$MARKER"

# --- Offline tests: run the whole print pipeline into a file, no printer involved ---
# offline_test NAME INPUT MIN_PAGES TIMEOUT_SECONDS [cupsfilter options...]
# A run that takes longer than TIMEOUT_SECONDS counts as hung and fails.
offline_test() {
  local name=$1 input=$2 min_pages=$3 limit=$4; shift 4
  local out="$WORK/$name.prn" log="$WORK/$name.log" pages waited=0
  local timed_out=false finished=false
  echo "Offline test: $name (up to ${limit}s)..."
  cupsfilter -p "$WORK/$PPD" -o PageSize="$PAGE_SIZE" "$@" -m printer/foo -e "$input" \
    > "$out" 2> "$log" &
  TEST_PID=$!
  while kill -0 "$TEST_PID" 2>/dev/null; do
    if (( waited >= limit )); then
      timed_out=true
      echo "  Timed out after ${limit}s: the driver looks hung." >&2
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if $timed_out; then
    stop_test
  elif wait "$TEST_PID"; then
    finished=true
  fi
  TEST_PID=""   # done; don't signal a reused process ID later
  if $finished; then
    pages=$(grep -c '^PAGE: ' "$log" || true)
    if ! grep -q '^ERROR:' "$log" \
       && (( pages >= min_pages )) \
       && [[ "$(head -c 9 "$out")" == $'\e%-12345X' ]]; then
      if grep -q "Raster header has no compression" "$log"; then
        echo "  Note: macOS left out the compression setting; the JBIG fallback was used."
      fi
      echo "  Passed: $pages page(s), $(wc -c < "$out" | tr -d ' ') bytes of printer data."
      return 0
    fi
  fi
  echo "Offline test '$name' FAILED. Filter log:" >&2
  { grep -v -E '^DEBUG: (argv|envp)' "$log" || true; } | tail -25 >&2
  return 1
}

printf 'Samsung %s offline test\n' "$MODEL" > "$WORK/short.txt"
# Long job: more pages than SpliX's 30-page memory cache, printed two-sided,
# so pages get swapped to disk and the cache thread is exercised.
for i in {1..3000}; do echo "Line $i of the long offline test"; done > "$WORK/long.txt"

if ! offline_test "one page" "$WORK/short.txt" 1 60 \
   || ! offline_test "long two-sided job" "$WORK/long.txt" 35 180 -o Duplex=DuplexNoTumble; then
  exit 1   # the exit handler rolls back
fi

# --- Add (or update) the printer queue. -E after -p enables it and accepts jobs. ---
# macOS prints a warning that printer drivers are deprecated; that is expected.
sudo -v
if ! sudo lpadmin -p "$QUEUE" -E -v "$URI" -P "$WORK/$PPD" \
       -D "Samsung $MODEL" -L "USB" -o PageSize="$PAGE_SIZE" -o printer-is-shared=false; then
  echo "lpadmin failed to add the printer." >&2
  exit 1   # the exit handler rolls back
fi
NEEDS_ROLLBACK=false

echo
echo "Installed. 'Samsung $MODEL' is ready and will appear in your apps' print dialogs."
echo "Send a test page with:  ./test-print.sh   (or ./test-print.sh --debug for detailed logs)"
