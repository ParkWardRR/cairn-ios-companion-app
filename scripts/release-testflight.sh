#!/usr/bin/env bash
# Archive the app and upload it to TestFlight on a named channel.
#
#   scripts/release-testflight.sh <beta|stable> [--export-only] [--allow-dirty]
#
# --export-only writes the .ipa to build/export and uploads nothing, which is the way to check
# the signing and the stamped identity without spending a build number.
# --allow-dirty is for trying the path out; a real release refuses an uncommitted tree, because
# a build whose commit stamp does not describe its source is worse than no stamp.
#
# What it does, stopping at the first failure:
#   1. refuse a dirty tree, and refuse a channel that is not beta or stable
#   2. fetch the pinned contracts and run swift test (333 tests, all CairnCore)
#   3. regenerate the Xcode project from project.yml, and fail if that leaves the tree dirty
#      (project.yml and the checked-in .xcodeproj must already agree)
#   4. archive, then export -- the store profile is only resolved at -exportArchive, so an
#      archive alone proves nothing about distribution (docs/carplay.md)
#
# Signing needs no credentials on this machine: Xcode's own account session authenticates the
# upload and signs with a cloud-managed distribution certificate. There is no distribution
# private key here, and there should not be one.
set -euo pipefail

CHANNEL="${1:?usage: release-testflight.sh <beta|stable> [--export-only] [--allow-dirty]}"
shift
EXPORT_ONLY=0; ALLOW_DIRTY=0
for a in "$@"; do
  case "$a" in
    --export-only) EXPORT_ONLY=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
case "$CHANNEL" in
  beta|stable) ;;
  dev) echo "dev is not a channel you upload: it is the working tree" >&2; exit 2 ;;
  *) echo "channel must be beta or stable, not '$CHANNEL'" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CairnCompanion"
BUILD="$ROOT/build"
cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
  if [ "$ALLOW_DIRTY" = 1 ]; then
    echo "!!  the tree is dirty and --allow-dirty was given: the commit stamp will not describe this build"
  else
    echo "the tree is dirty; commit first so the build's commit stamp means something" >&2
    git status --short >&2
    exit 1
  fi
fi

COMMIT="$(git rev-parse --short HEAD)"
VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$APP/project.yml")"
BUILD_NO="$(awk '/CURRENT_PROJECT_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$APP/project.yml")"
[ -n "$VERSION" ] && [ -n "$BUILD_NO" ] || { echo "could not read the version out of project.yml" >&2; exit 1; }

echo "==> $VERSION ($BUILD_NO) · $CHANNEL · $COMMIT"

echo "==> contracts"
"$ROOT/scripts/fetch-contracts.sh" >/dev/null

echo "==> swift test"
(cd "$APP" && swift test 2>&1 | tail -1)

echo "==> xcodegen"
(cd "$APP" && xcodegen generate >/dev/null)
if [ "$ALLOW_DIRTY" = 0 ] && [ -n "$(git status --porcelain)" ]; then
  echo "xcodegen changed the tree: project.yml and the committed .xcodeproj disagree" >&2
  git status --short >&2
  exit 1
fi

rm -rf "$BUILD/CairnCompanion.xcarchive" "$BUILD/export"
mkdir -p "$BUILD"

echo "==> archive"
xcodebuild archive \
  -project "$APP/CairnCompanion.xcodeproj" \
  -scheme CairnCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD/CairnCompanion.xcarchive" \
  -allowProvisioningUpdates \
  CAIRN_CHANNEL="$CHANNEL" \
  CAIRN_COMMIT="$COMMIT" \
  | tail -5

# Read the identity back out of the archive rather than trusting that the settings arrived.
STAMPED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$BUILD/CairnCompanion.xcarchive/Info.plist" 2>/dev/null || true)"
echo "==> archived version $STAMPED_VERSION, stamped as:"
/usr/libexec/PlistBuddy -c 'Print :CairnChannel' "$BUILD/CairnCompanion.xcarchive/Products/Applications/CairnCompanion.app/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CairnCommit' "$BUILD/CairnCompanion.xcarchive/Products/Applications/CairnCompanion.app/Info.plist"

OPTS="$APP/ExportOptions.plist"
if [ "$EXPORT_ONLY" = 1 ]; then
  OPTS="$BUILD/ExportOptions-export.plist"
  cp "$APP/ExportOptions.plist" "$OPTS"
  /usr/libexec/PlistBuddy -c 'Set :destination export' "$OPTS"
  echo "==> export only (nothing is uploaded)"
else
  echo "==> export and upload to App Store Connect"
fi

xcodebuild -exportArchive \
  -archivePath "$BUILD/CairnCompanion.xcarchive" \
  -exportPath "$BUILD/export" \
  -exportOptionsPlist "$OPTS" \
  -allowProvisioningUpdates \
  | tail -5

echo
echo "==> done: $VERSION ($BUILD_NO) · $CHANNEL · $COMMIT"
if [ "$EXPORT_ONLY" = 0 ]; then
  cat <<EOS

Processing in App Store Connect takes a few minutes. Then, by channel:
  beta    internal testers only; no review needed
  stable  assign the build to the external group, which needs Beta App Review

Neither step can be done from here: this machine uploads through Xcode's account session and
holds no App Store Connect API key.
EOS
fi
