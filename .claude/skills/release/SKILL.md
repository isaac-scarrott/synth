---
name: release
description: Cut a signed, notarized, public release of Synth and publish the Sparkle appcast that updates installed copies. Bumps app/VERSION, runs app/release.sh, verifies the published artifacts the way a stranger's Mac would, and appends the features ledger.
argument-hint: "[version, e.g. 0.1.1]"
disable-model-invocation: true
---

# Cut a release

Publishing is outward-facing and hard to walk back: it uploads to a public bucket, notarizes with
Apple, and moves every installed copy onto the new build. So this skill is invoked by hand
(`disable-model-invocation`) and never on inference. Reaching it means the user asked for it.

`app/release.sh` does the work — build, sign, notarize, staple, upload, publish the appcast, tag.
This skill is what surrounds it: choosing the version, proving the release actually landed, and
recording it. **Do not reimplement the pipeline.** If a step needs changing, change `release.sh`.

Releases run from Isaac's Mac. Everything the script needs already persists there: the Developer ID
certificate and the Sparkle EdDSA key in the login keychain, the `synth-notary` notarytool profile,
and the `tigris` AWS profile. There is no CI path.

## Before you run anything

1. **Pick the version.** Read `app/VERSION` (e.g. `0.1.0`). If the user named a version, use it.
   Otherwise bump the patch, and say which you chose. Semver — a feature bump is a minor.
2. **`app/releases/` must exist and hold the previous zips.** `generate_appcast` builds binary
   deltas by diffing against them, and CEF is ~93% of a 130MB bundle, so a delta is single-digit MB
   against a full download. The directory is gitignored and lives only on this Mac. If it is empty
   or missing, **stop and tell the user** — the release will still succeed but ships full-download
   updates only, silently. Recover by pulling the old zips back:
   `aws s3 sync s3://synth-releases/ app/releases/ --exclude "*" --include "Synth-*.zip" --endpoint-url https://fly.storage.tigris.dev --profile tigris`
3. **The working tree must be clean.** `release.sh` refuses a dirty tree, so commit first.

## Stamp the changelog

`app/Sources/Synth/Resources/CHANGELOG.json` is the in-app changelog (Synth → Changelog), read
from the bundle at runtime because the shipped `.app` carries no git repo. It must gain the new
version **before** the build, since `dist.sh` bundles it and the clean-tree guard needs it
committed. Prepend one object to the top of the array (the file is newest-first):

```json
{ "version": "0.1.1", "date": "<today, YYYY-MM-DD>", "changes": ["…", "…"] }
```

Draw the `changes` from the **FEATURES.md** one-line index entries added since the last released
version — curated, user-facing prose, not raw commits or the deep `docs/features/` text. Keep each
line short and outcome-first; omit internal/infra-only entries. This stamps the version boundary:
everything in the ledger above the previous release's line belongs to this version.

## Run it

```bash
# bump, commit, ship
printf '0.1.1\n' > app/VERSION
# …and prepend this version's entry to app/Sources/Synth/Resources/CHANGELOG.json (see above)
git commit -am "Synth 0.1.1"          # or fold into the release's real commits
cd app && ./release.sh
```

`release.sh` is non-interactive and guards itself: it aborts on a dirty tree, an existing tag, a
missing Developer ID certificate, an ad-hoc signature, an unreachable bucket, or a published feed
that is not anonymously readable. A failure means nothing shipped. **Never** work around a guard —
each one exists because the failure it catches is silent (see `docs/features/2026-07-10.md`).

Notarization waits on Apple, typically 5–10 minutes. That is normal; do not kill it.

## Prove it landed

The script's exit code is not proof. Verify as an outsider would — no credentials, quarantine set,
which is the exact state a browser download is in:

```bash
cd "$(mktemp -d)"
curl -fsSL -o S.zip https://synth-releases.fly.storage.tigris.dev/Synth.zip
ditto -x -k S.zip .
xattr -w com.apple.quarantine "0083;00000000;Safari;" Synth.app
spctl --assess --type execute --verbose=4 Synth.app     # want: accepted / source=Notarized Developer ID
xcrun stapler validate Synth.app                        # want: The validate action worked!
curl -fsSL https://synth-releases.fly.storage.tigris.dev/appcast.xml
```

In the appcast, check `sparkle:version` is the new build number (`git rev-list --count HEAD`) and
that an `sparkle:edSignature` is present on every enclosure. A missing signature means installed
copies will reject the update.

## Record it

Append a dated entry to `docs/features/<today>.md` and a one-line index entry to `FEATURES.md`
(never edit existing entries — the ledger is append-only, see CLAUDE.md). Say what shipped and why,
not that a release happened.

## Facts worth knowing

- **The Sparkle private key is irreplaceable.** Every installed copy trusts exactly one public key,
  baked into its binary. Lose the private half and no existing install can ever be updated again.
- **Update behaviour is set by the *running* app, not the new one.** A user on build N gets N's
  update behaviour when moving to N+1. Changes to `SUAutomaticallyUpdate` and friends only take
  effect for updates issued *from* a build that already has them.
- **`CFBundleVersion` is `git rev-list --count HEAD`,** not the marketing version. Sparkle orders
  releases by it, so it must only ever increase. `app/VERSION` is the human-facing string.
- The landing page's Download buttons point at the bucket's stable `Synth.zip` alias, so they never
  need updating per release.
