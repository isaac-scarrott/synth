#!/bin/bash
# Cut a public release: build, notarize, staple, and publish Synth plus the Sparkle appcast
# that tells installed copies an update exists.
#
#   ./release.sh
#
# Reads the version from ./VERSION — bump and commit that first. The source repo stays private and
# receives only the tag; every artifact goes to a public Tigris bucket on Fly.io, because Sparkle
# downloads with no credentials. One flat prefix hosts every version forever, so the appcast can
# name a two-year-old zip and have it still resolve.
#
# One-time setup, none of which this script can do for you:
#   1. A Developer ID Application certificate in the login keychain (Apple Developer > Certificates).
#   2. ./vendor/fetch-sparkle.sh && ./vendor/sparkle-tools/generate_keys
#      then put the printed public key in signing/ed25519-public.txt and commit it.
#   3. xcrun notarytool store-credentials synth-notary \
#        --key <AuthKey_XXXX.p8> --key-id <XXXX> --issuer <issuer-uuid>
#      (or --apple-id/--team-id/--password with an app-specific password, if you have no API key)
#   4. flyctl storage create --name synth-releases --public --org personal
#      then feed the printed keys to: aws configure --profile tigris
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

NOTARY_PROFILE="${SYNTH_NOTARY_PROFILE:-synth-notary}"
AWS_PROFILE_NAME="${SYNTH_TIGRIS_PROFILE:-tigris}"
VERSION="$(cat VERSION)"
TAG="v$VERSION"
ARCHIVE="releases"          # every published zip, kept so generate_appcast can build deltas
TOOLS="vendor/sparkle-tools"

die() { echo "release: $*" >&2; exit 1; }
s3() { aws s3 "$@" --endpoint-url "$TIGRIS_ENDPOINT" --profile "$AWS_PROFILE_NAME"; }

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit before releasing"
git rev-parse "$TAG" >/dev/null 2>&1 && die "$TAG already exists — bump VERSION"
command -v aws >/dev/null || die "aws CLI not found (brew install awscli)"
[ -f signing/ed25519-public.txt ] || die "signing/ed25519-public.txt missing — see setup above"

# The in-app changelog (Synth → Changelog) is read from the bundle, so a stale one ships
# silently. Guard the boundary: this version must already be stamped into CHANGELOG.json
# (see the release skill's "Stamp the changelog" step) before we build it in.
CHANGELOG="Sources/Synth/Resources/CHANGELOG.json"
grep -q "\"version\"[[:space:]]*:[[:space:]]*\"$VERSION\"" "$CHANGELOG" \
  || die "$CHANGELOG has no entry for $VERSION — stamp the changelog before releasing (see the release skill)"

aws s3api head-bucket --bucket "$RELEASE_BUCKET" \
  --endpoint-url "$TIGRIS_ENDPOINT" --profile "$AWS_PROFILE_NAME" >/dev/null 2>&1 \
  || die "cannot reach bucket $RELEASE_BUCKET as profile $AWS_PROFILE_NAME — see setup above"

IDENTITY="$(signing_identity)"
[ "$IDENTITY" != "-" ] || die "no Developer ID Application certificate — an ad-hoc build cannot be notarized"

./vendor/fetch-sparkle.sh

echo "==> Building $TAG (signing as: $IDENTITY)"
SYNTH_NO_INSTALL=1 ./dist.sh

APP="build/Synth.app"
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Gatekeeper's own verdict, not just codesign's. Pre-notarization this reports "rejected"
# with source=Unnotarized Developer ID — that is the expected answer here, and the check
# exists to catch the other failures (unsigned nested code, missing hardened runtime).
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> Notarizing (this uploads $(du -h build/Synth.zip | cut -f1) and waits on Apple)"
xcrun notarytool submit build/Synth.zip --keychain-profile "$NOTARY_PROFILE" --wait

# Staple the ticket into the .app so a first launch works with no network, then re-zip: the
# zip Apple notarized contains the un-stapled bundle, and a ticket cannot be stapled to a zip.
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /'

mkdir -p "$ARCHIVE"
ZIP="$ARCHIVE/Synth-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Archived $ZIP"

# The disk image is what a person downloads; the zip is what Sparkle downloads. It is built from
# the already-stapled app so the copy dragged to /Applications carries its own ticket and verifies
# with no network, then notarized in its own right because Gatekeeper assesses the image at mount.
# It stays out of $ARCHIVE: generate_appcast treats every archive it finds there as a release
# enclosure, and would publish the dmg as a second, competing update for this same version.
DMG="build/Synth-$VERSION.dmg"
echo "==> Building $DMG"
make_dmg "$APP" "$DMG" "Synth $VERSION" "$IDENTITY"

echo "==> Notarizing the disk image ($(du -h "$DMG" | cut -f1))"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# generate_appcast signs each zip with the private EdDSA key from the login keychain and, given
# older zips alongside, emits binary deltas between them. CEF is 93% of the bundle and changes
# only when it's re-vendored, so a delta between two ordinary Synth releases is a few MB against
# a 144MB full download. One flat bucket prefix serves every version, so unlike a per-release
# host, the URLs generate_appcast writes are already the URLs the objects will live at.
echo "==> Generating appcast + deltas"
"$TOOLS/generate_appcast" "$ARCHIVE" --download-url-prefix "$RELEASE_BASE_URL/"

shopt -s nullglob
DELTAS=("$ARCHIVE"/*.delta)
shopt -u nullglob
if [ ${#DELTAS[@]} -eq 0 ]; then
  echo "    no deltas (first release, or no prior zip in $ARCHIVE/) — full download only"
else
  echo "    ${#DELTAS[@]} delta(s), $(du -ch "${DELTAS[@]}" | tail -1 | cut -f1) total"
fi

# Binaries first. The appcast is the switch that makes a release live, so it goes last — and only
# once a stranger has been shown to be able to fetch what it points at. Zips and deltas are named
# per version and never change, so they cache forever; the appcast must not.
echo "==> Uploading artifacts to $RELEASE_BUCKET"
s3 sync "$ARCHIVE" "s3://$RELEASE_BUCKET/" \
  --exclude "appcast.xml" --exclude ".*" \
  --cache-control "public, max-age=31536000, immutable"

s3 cp "$DMG" "s3://$RELEASE_BUCKET/$(basename "$DMG")" \
  --cache-control "public, max-age=31536000, immutable"

# Stable names, so the landing page's links outlive every release. The zip alias stays because
# Sparkle's own installed copies were shipped pointing at it.
s3 cp "$DMG" "s3://$RELEASE_BUCKET/Synth.dmg" --cache-control "public, max-age=300"
s3 cp "$ZIP" "s3://$RELEASE_BUCKET/Synth.zip" --cache-control "public, max-age=300"

# One ranged byte proves reachability without pulling 144MB. The `aws` calls above used your keys
# and prove nothing about an updater or a stranger's browser, which carry none. Nothing is live
# yet if this fails.
echo "==> Checking the new artifacts are readable without credentials"
for artifact in "$(basename "$ZIP")" "$(basename "$DMG")" Synth.dmg; do
  curl -fsS --max-time 30 -r 0-0 -o /dev/null "$RELEASE_BASE_URL/$artifact" \
    || die "$RELEASE_BASE_URL/$artifact is not public — check the bucket is public. Nothing was published."
done

echo "==> Publishing appcast"
s3 cp "$ARCHIVE/appcast.xml" "s3://$RELEASE_BUCKET/appcast.xml" \
  --content-type "application/xml" --cache-control "public, max-age=300"
curl -fsS --max-time 30 -o /dev/null "$FEED_URL" \
  || die "appcast uploaded but $FEED_URL is not anonymously readable — installed copies will not update"

# Last, because a tag should record a release that happened. Only the tag leaves the private repo.
echo "==> Tagging $TAG (private source repo)"
git tag -a "$TAG" -m "Synth $VERSION"
git push origin "$TAG"

echo
echo "Released $TAG. Source stayed private; artifacts are public at $RELEASE_BASE_URL."
echo "Installed copies will see it at $FEED_URL within a day, or immediately"
echo "via Synth > Check for Updates…"
echo
echo "Landing page download link:  $RELEASE_BASE_URL/Synth.dmg"
echo "Keep $ARCHIVE/ — without the previous zips the next release ships no deltas."
