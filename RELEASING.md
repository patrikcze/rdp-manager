# Releasing

Releases are driven by git tags. A tag `vMAJOR.MINOR.PATCH` on `master` becomes the app's version and a GitHub release with the DMG.

## Versions
- `Scripts/version.sh` reads the version from the tags. The build scripts use it, so nothing in the repository needs a version bump.
  - On a tag `v0.3.0`: the app is **0.3.0**.
  - On a tag `v0.3.0-beta.1`: the app is **0.3.0-beta.1**, published as a pre-release.
  - Between tags: the last release plus a dev suffix, e.g. **0.3.0-dev.4+g1a2b3c4** (4 commits after v0.3.0). Before the first tag: **0.0.0-dev.N+g…**.
- In the bundle:
  - `CFBundleShortVersionString` gets the numeric part (0.3.0), because macOS allows only digits and dots there.
  - `RDPManagerVersion` gets the full version, which the About panel shows.
  - `CFBundleVersion` is the commit count, so it always increases.
- `VERSION=1.2.3` in the environment overrides the tag for a local build.

## Cutting a release
1. On `master`, rename the version's CHANGELOG section from `## 0.3.0 (unreleased)` to `## 0.3.0 (2026-11-20)`. Merge that through a PR as usual.
2. Tag and push:
   ```bash
   git checkout master && git pull
   Scripts/tag-release.sh 0.3.0 --push
   ```
   The script refuses to tag in these cases:
   - Off `master`.
   - With local changes.
   - Behind `origin/master`.
   - When the tag already exists.
   - When the CHANGELOG section is missing, empty, or still marked "unreleased".
3. The **Release** workflow (`.github/workflows/release.yml`) then:
   - Checks the tag's format and that it is on `master`.
   - Runs the tests.
   - Builds the DMG and checks that the app's version matches the tag.
   - Publishes `RDP-Manager-<version>.dmg` and its `.sha256` file. The release notes are the CHANGELOG section.

A failed release can be retried: delete the GitHub release, if one was created, and the tag (`git push origin :refs/tags/v0.3.0`). Then fix the problem and tag again.

## Signing
Without signing secrets the release DMG is ad-hoc signed, and the release notes tell users how to open it. For a Developer ID signed and notarized DMG, add these repository secrets (Settings › Secrets and variables › Actions):

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12`, the "Developer ID Application" certificate with its private key |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 export password |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | for notarization (an app-specific password from appleid.apple.com) |

The certificate goes into a temporary keychain that is deleted at the end of the job.

## CI
`.github/workflows/ci.yml` runs on every push to `master` and every pull request.
- **Secrets and scripts:**
  - gitleaks over the whole history.
  - Syntax check of `Scripts/*.sh`.
  - actionlint on the workflows.
- **Build, test and package** (macOS, Apple Silicon):
  - Gets FreeRDP from the cache, or builds it. The cache key covers the build script, its patches, the Homebrew library versions and the Xcode version.
  - Runs `swift build`, `swift test` and `Scripts/make-dmg.sh`, with signature and bundle checks.
  - Uploads the DMG as a build artifact for 14 days.

Repository variables (Settings › Secrets and variables › Actions › Variables) choose the build machine:
- `MACOS_RUNNER`: the runner label (default `macos-26`).
- `XCODE_VERSION`: the Xcode version, e.g. `26.1` (default `latest`, the newest installed release).

Third-party actions are avoided or pinned to a commit SHA (Dependabot keeps the pins current), and checkouts don't keep the job token, because the release job holds signing secrets and write access.
