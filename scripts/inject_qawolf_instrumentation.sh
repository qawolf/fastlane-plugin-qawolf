#!/usr/bin/env bash

## QA Wolf Instrumentation Injection Script
## ---------------------------------------
## This script injects QA Wolf's instrumentation.dylib into an IPA archive.
## It is equivalent to the `inject_qawolf_instrumentation` Fastlane action but can be
## used standalone on any macOS machine with the Xcode command‐line tools installed.
##
## Note that this IPA file has to be resigned after the injection.
##
## Usage:
##   ./inject_qawolf_instrumentation.sh -i path/to/input.ipa -o path/to/output.ipa [options]
##
## Options:
##   -i  Path to the input IPA (required)
##   -o  Path for the output IPA that will be created (required)
##   -t  Git tag/branch/commit of the `fastlane-plugin-qawolf` repo to fetch the dylib from (default: main)
##   -k  Keep the temporary working directory after finishing (useful for debugging)
##   -h  Show help
##
## Dependencies:
##   • curl, unzip, zip, /usr/libexec/PlistBuddy (part of Xcode tools) must be available in PATH.
##   • macOS is required because the injected binary targets iOS and relies on optool (Darwin only).
##
set -euo pipefail

function usage() {
  grep '^##' "$0" |grep -v "###" | cut -c 3-
  exit 1
}

# Default values
REPO_TAG="main"
KEEP_WORKDIR=0

while getopts "i:o:t:kh" opt; do
  case $opt in
    i) INPUT_IPA="$OPTARG" ;;
    o) OUTPUT_IPA="$OPTARG" ;;
    t) REPO_TAG="$OPTARG" ;;
    k) KEEP_WORKDIR=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ -z "${INPUT_IPA:-}" || -z "${OUTPUT_IPA:-}" ]]; then
  echo "❌ Error: -i and -o arguments are required." >&2
  usage
fi

# Verify input IPA exists
if [[ ! -f "$INPUT_IPA" ]]; then
  echo "❌ Input IPA not found at '$INPUT_IPA'" >&2
  exit 1
fi

# Create working directory
WORKDIR=$(mktemp -d -t qawolf_inject_XXXX)
if [[ "$KEEP_WORKDIR" == "1" ]]; then
  echo "ℹ️  Working directory: $WORKDIR (will be kept after execution)"
else
  trap 'rm -rf "$WORKDIR"' EXIT
fi

###############################################
# 1. Download instrumentation.dylib
###############################################
DYLIB_URL="https://raw.githubusercontent.com/qawolf/fastlane-plugin-qawolf/${REPO_TAG}/lib/fastlane/plugin/qawolf/assets/instrumentation.dylib"
DYLIB_PATH="$WORKDIR/instrumentation.dylib"

echo "🐺 Downloading instrumentation.dylib from $DYLIB_URL ..."
if ! curl -L --fail -o "$DYLIB_PATH" "$DYLIB_URL"; then
  echo "❌ Failed to download instrumentation.dylib from $DYLIB_URL" >&2
  exit 1
fi

###############################################
# 2. Download and extract optool
###############################################
OPTOOL_URL="https://github.com/alexzielenski/optool/releases/download/0.1/optool.zip"
OPTOOL_ZIP="$WORKDIR/optool.zip"
OPTOOL_DIR="$WORKDIR/optool_extract"

echo "🐺 Downloading optool from $OPTOOL_URL ..."
curl -L --fail -o "$OPTOOL_ZIP" "$OPTOOL_URL"
mkdir -p "$OPTOOL_DIR"
unzip -q "$OPTOOL_ZIP" -d "$OPTOOL_DIR"
OPTOOL_BIN=$(find "$OPTOOL_DIR" -type f -name optool | head -n 1)
if [[ -z "$OPTOOL_BIN" ]]; then
  echo "❌ Failed to locate optool binary inside downloaded archive." >&2
  exit 1
fi
chmod +x "$OPTOOL_BIN"

echo "ℹ️  optool binary: $OPTOOL_BIN"

###############################################
# 3. Unzip IPA
###############################################
EXTRACT_DIR="$WORKDIR/extracted"
mkdir -p "$EXTRACT_DIR"

echo "🐺 Extracting IPA ..."
unzip -q "$INPUT_IPA" -d "$EXTRACT_DIR"

APP_DIR=$(find "$EXTRACT_DIR/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)
if [[ -z "$APP_DIR" ]]; then
  echo "❌ No .app bundle found inside IPA" >&2
  exit 1
fi

PLIST="$APP_DIR/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "❌ Info.plist not found at $PLIST" >&2
  exit 1
fi

EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" || true)
if [[ -z "$EXECUTABLE_NAME" ]]; then
  echo "❌ Unable to read CFBundleExecutable from Info.plist" >&2
  exit 1
fi

BINARY_PATH="$APP_DIR/$EXECUTABLE_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "❌ App binary not found at $BINARY_PATH" >&2
  exit 1
fi

echo "ℹ️  App bundle: $APP_DIR"
echo "ℹ️  Executable binary: $BINARY_PATH"

###############################################
# 4. Inject dylib into the binary
###############################################
FRAMEWORKS_DIR="$APP_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

echo "🐺 Injecting instrumentation.dylib into $EXECUTABLE_NAME ..."
"$OPTOOL_BIN" install -c load -p "@loader_path/Frameworks/$(basename "$DYLIB_PATH")" -t "$BINARY_PATH"

###############################################
# 5. Copy dylib into Frameworks directory
###############################################
cp "$DYLIB_PATH" "$FRAMEWORKS_DIR"

echo "✅ Dylib copied to $FRAMEWORKS_DIR"

###############################################
# 6. Repackage IPA
###############################################
(
  cd "$EXTRACT_DIR"
  echo "🐺 Repackaging IPA to $OUTPUT_IPA ..."
  zip -qr "$OUTPUT_IPA" Payload
)

echo "🎉 Successfully created patched IPA at $OUTPUT_IPA"
