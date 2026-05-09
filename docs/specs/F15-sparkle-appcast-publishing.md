# F15 — Sparkle appcast publishing (enable auto-updates)

**Severity:** Low (deploy-time, no runtime regression)
**Audit cross-ref:** `_design/production-audit-2026-05-09.md` row F15 (also F10 for the placeholder safety guard)
**Component:** Release process — Sparkle update channel
**Status:** Open

---

## Summary

The app ships with a placeholder Sparkle feed URL:

- `Resources/Info.plist` → `SUFeedURL = https://example.invalid/voicemode-menubar/appcast.xml`
- `Resources/Info.plist` → `SUPublicEDKey = ""` (empty)

The hardening pass (F10) made the placeholder safe at runtime — `SparkleBridge` detects the `example.invalid` host (and the empty case) and starts the controller with `startingUpdater: false` so the periodic check never fires. No cold-launch error modal. But auto-updates are a deploy-time feature that is not yet live.

This spec is the lifecycle plan for standing up a real update channel: generate signing keys, host an appcast on GitHub Pages, and define the per-release workflow that produces signed `.zip` artifacts plus an updated `appcast.xml`.

The output of this spec is **operational** — it defines steps to execute, not Swift code to write. The only source-code touchpoints are two string fields in `Resources/Info.plist` (the public key and the feed URL) and (optionally) two helper scripts under `scripts/`.

---

## Goals

1. Stand up a real Sparkle update channel for `VoiceMode Monitor`.
2. Establish a repeatable per-release workflow that produces a signed, notarized, stapled `.app`, zips it, signs the zip with EdDSA, updates `appcast.xml`, and pushes via `git`.
3. Document failure modes (lost private key, public-key mismatch, missing staple) and mitigations.

## Non-goals

- Modifying any Swift source. Sparkle integration is already complete; this is purely operational.
- Migrating off GitHub Pages onto a different host (CDN, Fly, etc.). Pages is sufficient for this app's audience.
- Automating the release cut in CI / GitHub Actions. The first one is manual; CI automation is a follow-on.

---

## Hosting choice — recommendation

**Use the `docs/` folder of `main` branch as the GitHub Pages source.** Rationale:

- Single branch — the appcast and the source code live together. PR diffs that bump version + update appcast are reviewable as one unit.
- No `gh-pages` branch hygiene (rebase headaches, force-pushes, orphan history).
- `docs/specs/` already exists; co-locating `docs/appcast.xml` + `docs/releases/` is a natural extension.
- GitHub Pages serves at `https://williamruiz1.github.io/claude-code-jarvis-v/` once enabled.

The alternative — a `gh-pages` orphan branch — gains nothing for a single-app repo and adds branch-juggling overhead.

Pages URL: `https://williamruiz1.github.io/claude-code-jarvis-v/appcast.xml`

---

## Prerequisites

Install / confirm before starting:

1. **Sparkle CLI tooling.** The `generate_keys` and `generate_appcast` binaries ship inside the Sparkle SwiftPM checkout. After a release build they're at:

   ```
   .build/checkouts/Sparkle/bin/generate_keys
   .build/checkouts/Sparkle/bin/generate_appcast
   .build/checkouts/Sparkle/bin/sign_update
   ```

   (If the checkout has been cleaned, run `swift build -c release` once to repopulate it.)

   Optionally, install Sparkle's tools to a stable location with `brew install --cask sparkle` (Homebrew tap) — but the SPM-checked-out binaries are sufficient.

2. **Apple Developer ID signing identity.** Already established (team `5RRHNS4ZZB`, see `notarize_app.sh`). No change.

3. **`notarytool` keychain profile.** Already established as `VoiceModeNotary` per `notarize_app.sh` header. No change.

4. **GitHub Pages enabled** on `williamruiz1/claude-code-jarvis-v` with source = `Branch: main, Folder: /docs`. (Settings → Pages.) This is one of the one-time-setup steps below.

5. **A safe place to back up the EdDSA private key.** Bitwarden vault, encrypted disk, or a printout in a safe — anywhere that survives a Mac wipe. The Keychain is the working store; the backup is the disaster-recovery store.

---

## One-time setup (do exactly once)

### Step 1 — Generate the EdDSA keypair

```bash
cd /Users/williamruiz/code/voicemode-menubar
swift build -c release         # populates .build/checkouts/Sparkle if missing
.build/checkouts/Sparkle/bin/generate_keys
```

`generate_keys` does two things:

- Stores the **private key** in the macOS login Keychain under service `https://sparkle-project.org` (Sparkle's default — this is where `generate_appcast` will look for it). No `account=$USER, service=sparkle-eddsa-private-key` override is needed and would break `generate_appcast`'s lookup; leave the default.
- Prints the **public key** to stdout as a base64 string (about 44 characters, ending in `=`).

Copy the public key string. **Back up the private key** — see Step 2.

### Step 2 — Back up the private key (disaster recovery)

The private key lives only in this Mac's login Keychain. Lose the Mac → lose the key → can never sign new releases for existing users. Mitigation:

```bash
.build/checkouts/Sparkle/bin/generate_keys -x ~/Desktop/sparkle-eddsa-backup.pem
```

(`-x` exports the private half to a file. The Sparkle docs explicitly support this for transferring to another Mac; we use it for backup.)

Move `sparkle-eddsa-backup.pem` to:

- Bitwarden as a secure note (paste contents inline), OR
- An encrypted disk image / USB stick stored offline, OR
- Both.

**Then `rm -P` the file from `~/Desktop/`** so it doesn't sit unencrypted on disk. To restore on a new Mac: `generate_keys -f sparkle-eddsa-backup.pem` re-imports it into the new Keychain.

### Step 3 — Update `Resources/Info.plist`

Replace two string values:

- `SUPublicEDKey` → paste the public key string from Step 1.
- `SUFeedURL` → `https://williamruiz1.github.io/claude-code-jarvis-v/appcast.xml`

That's it. No other plist keys change. `SparkleBridge.swift` already detects the placeholder logic — once the URL is no longer `example.invalid`, the periodic check turns back on automatically.

### Step 4 — Enable GitHub Pages

In the GitHub web UI: `Settings` → `Pages` → `Build and deployment` → `Source: Deploy from a branch` → `Branch: main` / `Folder: /docs` → Save.

Pages takes ~1 minute to provision. Confirm with:

```bash
curl -I https://williamruiz1.github.io/claude-code-jarvis-v/
```

Expect `HTTP/2 200` (or 404 until the first commit lands a file under `docs/` — `docs/specs/` already exists, so the URL should resolve to a directory listing or `404` depending on Jekyll defaults).

### Step 5 — Smoke-test a freshly built app

```bash
./build_app.sh
```

Cold launch the app. With the placeholder URL replaced, `SparkleBridge` should now start the periodic check normally. The first check will hit the appcast URL — at this point `appcast.xml` doesn't exist yet (404 from Pages), and Sparkle will log a "no updates available" / network error silently (no modal, because we're past the placeholder gate). This is expected — the appcast lands in the first release-cut workflow below.

### One-time-setup acceptance criteria

- [ ] `generate_keys` ran without error; public key copied; private key in Keychain.
- [ ] Private key backed up to Bitwarden (or equivalent), backup file removed from disk.
- [ ] `Resources/Info.plist` has the real `SUPublicEDKey` and `SUFeedURL`. No `example.invalid` remaining.
- [ ] GitHub Pages serving `https://williamruiz1.github.io/claude-code-jarvis-v/` with HTTP 200 on the root.
- [ ] Fresh build of the app launches without error and without the Sparkle update modal.

---

## Per-release workflow (do every time a new version ships)

Run these in order. There is no automation yet — each step is a manual command. (See "Future work" for `scripts/cut-release.sh`.)

### Step 1 — Bump the version

Edit `Resources/Info.plist`:

- `CFBundleShortVersionString` — semver, user-facing. Example: `0.2.0` → `0.3.0`.
- `CFBundleVersion` — monotonic build integer. Sparkle compares this to decide "newer than installed". Example: `20` → `21`. **Always increment**, even for the same `CFBundleShortVersionString`.

### Step 2 — Build (release path)

```bash
./build_app.sh
```

Produces `/Applications/VoiceMode Monitor.app`, signed with Developer ID + hardened runtime + secure timestamp. (See `build_app.sh` header for env-var overrides.)

### Step 3 — Notarize and staple

```bash
./notarize_app.sh "/Applications/VoiceMode Monitor.app"
```

The script submits to Apple, waits for `Accepted`, and runs `xcrun stapler staple` automatically on success. Confirm the staple landed:

```bash
xcrun stapler validate "/Applications/VoiceMode Monitor.app"
# Expect: "The validate action worked!"
```

If notarization fails, fix the cause (typically a missing `--options runtime` somewhere in nested signing) and re-run. Do not proceed to the next step with an un-stapled app.

### Step 4 — Zip the .app for distribution

```bash
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "/Applications/VoiceMode Monitor.app/Contents/Info.plist")"

mkdir -p docs/releases
ditto -c -k --keepParent \
  "/Applications/VoiceMode Monitor.app" \
  "docs/releases/VoiceMode-Monitor-${VERSION}.zip"
```

`ditto -c -k --keepParent` is the canonical macOS app-zip incantation — it preserves resource forks, symlinks, and the outer `.app` directory. Use nothing else (a `zip -r` from BSD `zip` strips metadata Sparkle needs for staple validation).

### Step 5 — Generate / regenerate the appcast

```bash
.build/checkouts/Sparkle/bin/generate_appcast \
  docs/releases/ \
  --download-url-prefix https://williamruiz1.github.io/claude-code-jarvis-v/releases/
```

What this does:

- Scans `docs/releases/` for all `.zip` files matching the convention.
- For each zip: reads the embedded `Info.plist` to extract `CFBundleShortVersionString` + `CFBundleVersion`, computes `length` (bytes), runs `sign_update` against the private key in the Keychain to produce `sparkle:edSignature`, and emits an `<item>` with `enclosure url="https://williamruiz1.github.io/claude-code-jarvis-v/releases/<filename>.zip"`.
- Writes `docs/releases/appcast.xml` with all items, newest first (sorted by `CFBundleVersion`).

**Move the appcast to where `SUFeedURL` expects it:**

```bash
mv docs/releases/appcast.xml docs/appcast.xml
```

(The `--download-url-prefix` flag pre-rewrites the enclosure URLs; the file just needs to live at the path Pages serves it from. We chose `docs/appcast.xml` so the URL is `…/appcast.xml`, not `…/releases/appcast.xml`.)

### Step 6 — Release notes (per-release)

For each release zip, drop a one-page HTML changelog at `docs/releases/<version>.html`. Format:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>VoiceMode Monitor 0.3.0 — release notes</title>
  <style>
    body { font: -apple-system-body; max-width: 36em; margin: 2em auto; padding: 0 1em; }
    h1 { font-size: 1.4em; }
    h2 { font-size: 1.1em; margin-top: 1.5em; }
    li { margin-bottom: 0.3em; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; }
  </style>
</head>
<body>
  <h1>VoiceMode Monitor 0.3.0</h1>
  <p>Released YYYY-MM-DD.</p>
  <h2>What's new</h2>
  <ul>
    <li>…</li>
  </ul>
  <h2>Fixes</h2>
  <ul>
    <li>…</li>
  </ul>
</body>
</html>
```

Then add the release-notes link to the appcast. `generate_appcast` does NOT auto-link release notes; add it by hand once per release (or post-process):

```xml
<sparkle:releaseNotesLink>
  https://williamruiz1.github.io/claude-code-jarvis-v/releases/0.3.0.html
</sparkle:releaseNotesLink>
```

(Insert this inside the matching `<item>` block in `docs/appcast.xml`.)

### Step 7 — Commit + push

```bash
git add Resources/Info.plist \
        docs/appcast.xml \
        docs/releases/VoiceMode-Monitor-${VERSION}.zip \
        docs/releases/${VERSION}.html
git commit -m "release: ${VERSION}"
git push origin main
```

GitHub Pages re-deploys within 1–2 minutes. Confirm with:

```bash
curl -sI "https://williamruiz1.github.io/claude-code-jarvis-v/appcast.xml" | head -3
curl -sI "https://williamruiz1.github.io/claude-code-jarvis-v/releases/VoiceMode-Monitor-${VERSION}.zip" | head -3
```

Both must return `HTTP/2 200`.

### Step 8 — Tag the release

```bash
git tag "v${VERSION}"
git push --tags
```

Optionally: also create a GitHub Release that mirrors the same `.zip` (gives non-Sparkle users a discoverable download link). Use `gh release create v${VERSION} docs/releases/VoiceMode-Monitor-${VERSION}.zip --notes-file docs/releases/${VERSION}.html`.

### Step 9 — Verify auto-update from the user perspective

On a Mac running an older build of the app (e.g. `CFBundleVersion = 20`, before the bump to `21`):

1. Open `VoiceMode Monitor` → menu-bar dropdown → `Check for Updates…`
2. Sparkle should fetch `appcast.xml`, find a newer build, show the "An update is available" sheet with the release notes (if linked).
3. Accept → Sparkle downloads the zip, verifies the EdDSA signature against the embedded public key, replaces the running app, and relaunches.
4. The new app should open and reflect the bumped version (About panel shows `0.3.0 (21)`).

If the verify fails (signature mismatch), see "Failure modes" below.

### Per-release acceptance criteria

- [ ] `Resources/Info.plist` shows the bumped `CFBundleShortVersionString` and `CFBundleVersion`.
- [ ] `docs/releases/VoiceMode-Monitor-<version>.zip` exists and unzips to a stapled .app.
- [ ] `docs/appcast.xml` contains an `<item>` for the new release with a non-empty `sparkle:edSignature` and the correct `length`.
- [ ] `https://williamruiz1.github.io/claude-code-jarvis-v/appcast.xml` returns 200 with the new item.
- [ ] An older build of the app, on `Check for Updates…`, finds the new release and installs it cleanly.
- [ ] `git tag v<version>` exists and is pushed.

### First-release acceptance (special case for the initial cut)

In addition to the above:

- [ ] This is the first time `appcast.xml` exists at the Pages URL.
- [ ] To exercise the discovery path, build the app twice with a one-tick version bump in between (e.g. cut `0.3.0` and `0.3.1` back-to-back) so an installed `0.3.0` has something newer to find.

---

## Helper scripts (future work — not part of this task)

The spec calls these out for the next iteration. **Do not implement as part of F15** — implement after the first manual release-cut succeeds, so the script encodes a known-good flow.

### `scripts/cut-release.sh`

One-shot release-cut. Takes a target version on the command line:

```bash
./scripts/cut-release.sh 0.3.0 21
```

Performs Steps 1–8 of the per-release workflow above, prompting before the `git push` so the operator can review the diff. Errors out cleanly on any failure (notarize rejection, missing key, etc.) and leaves the working tree in a recoverable state.

### `scripts/verify-appcast.sh`

Sanity-checks the published appcast. No arguments:

```bash
./scripts/verify-appcast.sh
```

Steps:

1. Fetch `docs/appcast.xml` (local) AND `https://williamruiz1.github.io/claude-code-jarvis-v/appcast.xml` (remote). Diff them — any mismatch means a push didn't deploy yet (warn, don't fail).
2. For each `<item>`: extract the enclosure URL and `sparkle:edSignature`, `curl -I` the URL (must be 200), `curl` the bytes, run `sign_update -p <pubkey> --verify <sig> <bytes>` using the public key from `Resources/Info.plist`. All must verify.
3. Confirm items are sorted newest-first by `sparkle:version`.
4. Print PASS / FAIL per item + summary.

---

## Failure modes and mitigations

### F-1: Lost private key

**Cause:** Mac wiped, Keychain corrupted, or never backed up.

**Effect:** Cannot sign new releases. Any user on an existing build that contains the matching `SUPublicEDKey` cannot auto-update — Sparkle refuses unsigned items. To roll forward you'd have to ship a new app with a *new* `SUPublicEDKey`, manually distributed (the existing user base never sees it via auto-update).

**Mitigation:** Step 2 of the one-time setup. **Back up the private key to Bitwarden (or equivalent) immediately after generating it.** Treat the key with the same care as a code-signing certificate.

### F-2: Public key in `Info.plist` mismatches the private key used to sign

**Cause:** Someone re-ran `generate_keys` (which silently creates a new keypair if the existing one isn't found) without updating `Resources/Info.plist`.

**Effect:** Every auto-update attempt fails the EdDSA verification. Users see "Update is improperly signed" and stay on the old build.

**Mitigation:** Always source the public key from the *same* `generate_keys` run that produced the private key now in the Keychain. If in doubt:

```bash
.build/checkouts/Sparkle/bin/generate_keys -p
# Prints the public key for the keypair currently in the Keychain.
# Compare to SUPublicEDKey in Resources/Info.plist — they must match exactly.
```

If mismatch is discovered after release: ship a new version with the correct public key and document the gap; users on the affected build will need a manual download.

### F-3: Stapler not run after notarization

**Cause:** Notarytool returned `Accepted` but `xcrun stapler staple` was skipped (or failed silently).

**Effect:** Sparkle's pre-install validator (which on recent macOS is notarization-aware) may reject the downloaded zip with "App is damaged" or "Cannot verify developer". Updates fail at the install step.

**Mitigation:** `notarize_app.sh` already runs `stapler staple` automatically after a successful notarytool result. Confirm with `xcrun stapler validate "/Applications/VoiceMode Monitor.app"` before zipping. If the validate fails, re-staple (don't zip a non-stapled app).

### F-4: GitHub Pages caching stale content

**Cause:** Pages CDN sometimes serves stale content for a few minutes after a push.

**Effect:** Newly cut release isn't discovered by users for ~5 minutes.

**Mitigation:** Just wait. If a verification check fails immediately after push, retry after 2 minutes. Don't add cache-busting query strings to the appcast — Sparkle hits the URL exactly as configured in `SUFeedURL`.

### F-5: Build with `VOICEMODE_NO_SPARKLE=1` accidentally shipped

**Cause:** Operator forgot the env var was set in their shell profile.

**Effect:** The shipped binary has a stub `SparkleBridge` and can never receive updates. (Fatal for that user — they have to manually download the next release.)

**Mitigation:** Add an explicit `unset VOICEMODE_NO_SPARKLE` at the top of `scripts/cut-release.sh` (when implemented). For manual cuts, sanity-check the built app with `otool -L "/Applications/VoiceMode Monitor.app/Contents/MacOS/VoiceModeMenuBar" | grep -i sparkle` — must show `Sparkle.framework` linked.

---

## Out of scope

- CI / GitHub Actions automation of the release-cut. Defer until the manual flow has been exercised at least twice.
- Multiple release channels (stable / beta) via `sparkle:channel`. The app currently has no setting to opt into a non-stable channel.
- Delta updates (Sparkle's `generate_appcast` produces them automatically when source `.app`s are present, but that adds disk pressure to the repo). Revisit if release zips exceed ~50 MB.
- Migrating `SUFeedURL` off GitHub Pages onto a custom domain. Possible later; not needed for v1.

---

## Open questions

- **None.** The path is defined end-to-end. If `generate_appcast` flags drift in a future Sparkle release, update Step 5 of the per-release workflow accordingly.

---

## References

- Sparkle EdDSA signing: https://sparkle-project.org/documentation/eddsa-signing/
- Sparkle publishing / appcast format: https://sparkle-project.org/documentation/publishing/
- F10 fix (placeholder safety guard): `_design/production-audit-2026-05-09.md` row F10
- Existing release scripts: `build_app.sh`, `notarize_app.sh`
- Existing README section: `README.md` § "Sparkle appcast publishing" (this spec supersedes that section once executed; update the README to point here as part of the first release cut).
