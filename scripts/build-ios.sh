#!/usr/bin/env bash
#
# Build an UNSIGNED Witchsky iOS .ipa.
#
# This script owns the *build steps* and nothing about how the toolchain is
# installed. It assumes `node`, `pnpm`, `jq`, `pod` (CocoaPods) and Xcode's
# `xcodebuild` are already on PATH. Get them either way:
#
#   * locally:  `nix develop .#ios`  (see flake.nix) + an installed Xcode
#   * in CI:    marketplace actions   (see .forgejo/workflows/build-ios-unsigned.yml)
#
# Xcode itself is intentionally NOT provided by nix -- install it externally
# and select it with `xcode-select`.
#
# Xcode 26+ ships the iOS *device platform* as a separately-installed
# component: a fresh Xcode has the iphoneos SDK on disk (so `pod install` and
# codegen work) but NO device platform, and `xcodebuild archive` then dies with
# "Found no destinations for the scheme ... and action archive". Install it once
# per machine (and per CI host):  xcodebuild -downloadPlatform iOS
#
# Env overrides:
#   IPA_OUT         output path for the .ipa    (default: <repo>/artifacts/Witchsky.ipa)
#   PREBUILD_CLEAN  1 = `expo prebuild --clean` (default), 0 = reuse existing ios/
#   ARCHIVE_PATH    xcarchive location          (default: a fresh temp dir)
#
set -euo pipefail

# --- location ---------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="Witchsky"
WORKSPACE="ios/${SCHEME}.xcworkspace"
# Default ON: expo prebuild's incremental (reuse) mode mis-handles this project's
# App Clip / extension targets (duplicate AppDelegate, missing Supporting/
# Expo.plist) -- only --clean regenerates a consistent ios/. PREBUILD_CLEAN=0 to
# reuse an existing ios/.
PREBUILD_CLEAN="${PREBUILD_CLEAN:-1}"

# Absolutise IPA_OUT so we can `cd` around freely when zipping.
IPA_OUT="${IPA_OUT:-$REPO_ROOT/artifacts/${SCHEME}.ipa}"
mkdir -p "$(dirname "$IPA_OUT")"
IPA_OUT="$(cd "$(dirname "$IPA_OUT")" && pwd)/$(basename "$IPA_OUT")"

ARCHIVE_PATH="${ARCHIVE_PATH:-$(mktemp -d)/${SCHEME}.xcarchive}"

# CocoaPods/Ruby abort without a UTF-8 locale; expo prebuild refuses a dirty tree.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export EXPO_NO_GIT_STATUS=1
# Unbuffer xcodebuild output so the CI log streams live -- and a hang shows its
# last real line instead of vanishing behind a killed job's buffer.
export NSUnbufferedIO=YES
# NB: do NOT enable ccache (USE_CCACHE). The Podfile then wires RN's
# ccache-clang.sh wrapper as CC/LD, whose relative path resolves to a broken
# /../../node_modules/... for the extension targets (BlueskyNSE/Clip) and fails
# the link. The reference build never used it; unsigned builds are ~20-40min raw.
# Xcode must compile with Apple's clang + SDK. A nix devShell can leak C/C++
# include paths and flags that pull nix's libc++ into the build and clash with
# the Apple SDK (undeclared _CTYPE_*, unresolved using-declarations in <cwchar>,
# "compiler was not recognized"). Strip them so xcodebuild sees a clean,
# Apple-only toolchain. (mkShellNoCC in the flake avoids setting most of these;
# this is belt-and-suspenders and also covers marketplace-action CI.)
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
  OBJCPLUS_INCLUDE_PATH LIBRARY_PATH NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS

log() { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }

# --- preflight --------------------------------------------------------------
missing=0
for tool in node pnpm jq pod xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' not found on PATH" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "Get the toolchain first: 'nix develop .#ios' (and install Xcode)." >&2
  exit 1
fi

# Pretty log formatter -- ONLY on an interactive TTY. In CI (non-tty) stream
# xcodebuild raw: piping a long archive through xcbeautify/xcpretty can deadlock
# (xcodebuild blocks writing to a formatter that stops draining -> the build
# hangs with no CPU until the job times out), and raw output is what you want in
# a CI log anyway.
# `formatter` stays non-empty (safe under `set -u` on any bash, incl. macOS 3.2);
# `use_pretty` decides whether to actually pipe xcodebuild through it.
formatter=(cat)
use_pretty=0
if [ -t 1 ]; then
  if command -v xcbeautify >/dev/null 2>&1; then
    formatter=(xcbeautify); use_pretty=1
  elif command -v xcpretty >/dev/null 2>&1; then
    formatter=(xcpretty); use_pretty=1
  fi
fi

# --- js deps + translations -------------------------------------------------
log "Installing JS dependencies (pnpm)"
pnpm install --frozen-lockfile

log "Compiling translations"
pnpm intl:build

# --- build-time env vars ----------------------------------------------------
# These EXPO_PUBLIC_* values are inlined from .env at build time. Update only
# these three keys in place so a locally-configured .env (proxy DIDs, Sentry
# DSN, ...) survives. .env is gitignored, so on a fresh CI checkout this just
# creates it.
log "Setting build-time env vars in .env"
set_env() { # <key> <value>
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  if [ -f .env ]; then grep -v "^${key}=" .env > "$tmp" || true; fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" .env
}
set_env EXPO_PUBLIC_RELEASE_VERSION  "$(jq -r '.version' package.json)"
set_env EXPO_PUBLIC_BUNDLE_IDENTIFIER "$(git rev-parse HEAD)"
set_env EXPO_PUBLIC_BUNDLE_DATE       "$(date -u +'%y%m%d%H')"

# app.config.js references ./google-services.json unconditionally; a real
# Firebase project is not required for an unsigned build.
[ -f google-services.json ] || cp google-services.json.example google-services.json

# --- generate the native ios project ---------------------------------------
log "Running expo prebuild (ios)"
prebuild_args=(--platform ios --no-install)
[ "$PREBUILD_CLEAN" = "1" ] && prebuild_args+=(--clean)
pnpm exec expo prebuild "${prebuild_args[@]}"

log "Copying assets into ios/${SCHEME}"
cp -R assets/. "ios/${SCHEME}/" 2>/dev/null || true

# --- pods -------------------------------------------------------------------
# Run CocoaPods directly -- the nix `cocoapods` (and CI's setup-cocoapods) ship
# a `pod` with a working `ffi`, so there is no bundler/Gemfile step and the
# repo's stale `.ruby-version` 2.7.6 pin (predates ffi>=3.0) is never evaluated.
log "Installing pods"
( cd ios && pod install )

# --- fmt consteval patch ----------------------------------------------------
# Clang 26 rejects the pointer arithmetic inside fmt's consteval
# basic_format_string constructor. fmt already falls back to constexpr for
# older Apple clang; extend that to newer toolchains. constexpr is functionally
# identical (compile-time where possible, runtime otherwise). Safe no-op on
# older Xcode or if the macro isn't present.
fmt_base_h="$(find ios/Pods -path '*/fmt/include/fmt/base.h' 2>/dev/null | head -1 || true)"
if [ -n "$fmt_base_h" ]; then
  log "Patching fmt consteval -> constexpr ($fmt_base_h)"
  # CocoaPods installs fmt's headers read-only (mode 0444). The nix devShell
  # puts GNU coreutils `mv` on PATH, which -- on an interactive TTY -- PROMPTS
  # before clobbering a read-only file ("mv: replace ..., overriding mode
  # 0444?") and blocks the whole build forever with no compiler ever starting.
  # (Non-tty stdin silently overwrites, so it only bites local terminal runs.)
  # chmod it writable and overwrite in place so the patch always applies
  # unattended -- no mv, no prompt, identical on BSD/GNU.
  tmp="$(mktemp)"
  sed 's/#  define FMT_CONSTEVAL consteval/#  define FMT_CONSTEVAL constexpr/' \
    "$fmt_base_h" > "$tmp"
  chmod u+w "$fmt_base_h"
  cat "$tmp" > "$fmt_base_h"
  rm -f "$tmp"
fi

# --- archive ----------------------------------------------------------------
log "Archiving (unsigned, arm64, Release)"
rm -rf "$ARCHIVE_PATH"
archive=(xcodebuild archive
  -workspace "$WORKSPACE"
  -scheme "$SCHEME"
  -archivePath "$ARCHIVE_PATH"
  -sdk iphoneos
  -arch arm64
  -configuration Release
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  CODE_SIGNING_ALLOWED=NO)
if [ "$use_pretty" = 1 ]; then
  "${archive[@]}" | "${formatter[@]}"
else
  "${archive[@]}"   # CI: stream raw (unbuffered), no formatter pipe to deadlock on
fi

# --- package the ipa --------------------------------------------------------
log "Packaging IPA"
stage="$(mktemp -d)"
mkdir -p "$stage/Payload"
cp -R "$ARCHIVE_PATH/Products/Applications/${SCHEME}.app" "$stage/Payload/"
rm -f "$IPA_OUT"
( cd "$stage" && zip -qry "$IPA_OUT" Payload )

log "Done: $IPA_OUT"
