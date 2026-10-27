#!/bin/zsh
# Builds the SpliX filter and PPDs for the Samsung ML-1860 series.
# Output goes to ./build. Run ./install.sh afterwards.
set -euo pipefail
cd "${0:A:h}"

SPLIX_REPO="https://github.com/OpenPrinting/splix.git"
SPLIX_COMMIT="7a802180c7b50802aaa16bbd2b3e326237286730"
FILTER_PATH="/Library/Printers/Samsung/Filter/rastertoqpdl"
MODELS=(ml1860 ml1865 ml1670)   # same driver settings and USB ID; only names differ
BUILD="build"
SPLIX="$BUILD/splix"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Requirements ---
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == 1 ]]; then
  fail "This Terminal is running under Rosetta (Intel mode) on an Apple Silicon Mac.
Open Terminal normally (Get Info → untick \"Open using Rosetta\") and run ./build.sh again."
fi
xcode-select -p >/dev/null 2>&1 \
  || fail "Xcode Command Line Tools are needed. Install them with: xcode-select --install"
for tool in git python3 clang++; do
  command -v "$tool" >/dev/null || fail "$tool wasn't found. It comes with the Xcode Command Line Tools."
done
for tool in ppdc cupstestppd; do
  command -v "$tool" >/dev/null || fail "$tool (part of macOS's printing system) wasn't found."
done
command -v brew >/dev/null || fail "Homebrew is needed. See https://brew.sh"
if ! brew list --versions jbigkit >/dev/null 2>&1; then
  echo "Installing jbigkit (JBIG compression library) with Homebrew..."
  HOMEBREW_NO_AUTO_UPDATE=1 brew install jbigkit
fi
JBIG=$(brew --prefix jbigkit)
JBIG_VERSION=$(brew list --versions jbigkit)
[[ -f "$JBIG/lib/libjbig85.a" ]] || fail "libjbig85.a not found in $JBIG/lib."

# --- Fetch SpliX at the pinned commit and apply our patch ---
mkdir -p "$BUILD"
if [[ -d "$SPLIX" && ! -d "$SPLIX/.git" ]]; then
  rm -rf "$SPLIX"   # left over from an interrupted download
fi
if [[ ! -d "$SPLIX/.git" ]]; then
  echo "Downloading SpliX..."
  git clone --quiet "$SPLIX_REPO" "$SPLIX"
fi
# Fetch if the pinned commit is newer than the existing download.
if ! git -C "$SPLIX" cat-file -e "$SPLIX_COMMIT^{commit}" 2>/dev/null; then
  echo "Updating the SpliX download..."
  git -C "$SPLIX" fetch --quiet origin
fi
git -C "$SPLIX" checkout --quiet --force "$SPLIX_COMMIT" \
  || fail "Couldn't check out SpliX commit $SPLIX_COMMIT."
git -C "$SPLIX" clean --quiet -fdx
git -C "$SPLIX" apply "$PWD/patches/splix-macos.patch"
echo "SpliX ${SPLIX_COMMIT:0:7}, patched."

# --- Compile the filter ---
echo "Compiling rastertoqpdl..."
SRC=(rastertoqpdl request printer qpdl document core compress algorithm ppdfile
     page colors band bandplane cache rendering semaphore
     algo0x0d algo0x0e algo0x11 algo0x13 algo0x15)
SRC_FILES=()
for s in "${SRC[@]}"; do SRC_FILES+=("$SPLIX/src/$s.cpp"); done
clang++ -std=c++11 -O2 -Wall -Wno-deprecated-declarations -Wno-missing-braces \
  -I"$SPLIX/include" -I"$JBIG/include" -DTHREADS=2 -DCACHESIZE=30 \
  "${SRC_FILES[@]}" "$JBIG/lib/libjbig85.a" -lcups -lcupsimage -lpthread \
  -o "$BUILD/rastertoqpdl"

# --- Generate the PPDs from SpliX's own printer definitions ---
echo "Generating PPDs..."
mkdir -p "$BUILD/ppdc"
python3 -I tools/flatten-drv.py "$SPLIX/ppd/samsung.drv.in" "$FILTER_PATH" > "$BUILD/ppdc/samsung.drv"
ppdc -I "$SPLIX/ppd" -d "$BUILD/ppdc/out" "$BUILD/ppdc/samsung.drv"
mkdir -p "$BUILD/ppd"
for m in "${MODELS[@]}"; do
  cp "$BUILD/ppdc/out/$m.ppd" "$BUILD/ppd/"
  cupstestppd -q -I filters "$BUILD/ppd/$m.ppd" || fail "$m.ppd failed validation."
done

# --- Checksums, so install.sh can tell if the files change afterwards ---
( cd "$BUILD" && shasum -a 256 rastertoqpdl ppd/*.ppd > SHA256SUMS )

# --- Record what this was built with (useful in bug reports) ---
cat > "$BUILD/BUILDINFO" <<EOF
splix: $SPLIX_COMMIT
patch: $(shasum -a 256 patches/splix-macos.patch | awk '{print $1}')
jbigkit: ${JBIG_VERSION#jbigkit }
compiler: $(clang++ --version | head -1)
macos: $(sw_vers -productVersion) $(uname -m)
EOF

echo
echo "Built:"
echo "  $BUILD/rastertoqpdl"
for m in "${MODELS[@]}"; do echo "  $BUILD/ppd/$m.ppd"; done
sed 's/^/  /' "$BUILD/BUILDINFO"
echo "Next: ./install.sh --model ML-1865   (or ML-1860 / ML-1670)"
