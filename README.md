# Posty

Posty is a native macOS PostgreSQL client built with Swift 6, SwiftUI, focused AppKit bridges, XcodeGen, and PostgresNIO.

## Install

Release builds are signed and notarized universal apps for Apple silicon and Intel Macs running macOS 26 or newer.
The repository and downloads are private; your GitHub account must have access. With `gh` already signed in:

```sh
brew tap coryoso/homebrew https://github.com/coryoso/homebrew.git
HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install --cask coryoso/homebrew/posty
```

Use the same token environment variable with `brew upgrade --cask coryoso/homebrew/posty`.
The public tap contains the cask definition; the app archive stays in the private repository.

## Requirements

- macOS 26 and Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An installed `codex` CLI configured with the `azure` provider and access to `gpt-5.6-luna` and `gpt-5.6-terra` for AI features

## Build

```sh
xcodegen generate
open Posty.xcodeproj
```

The generated Xcode project is intentionally not the source of truth. Change `project.yml`, then regenerate it.

For a command-line build:

If `xcode-select -p` points to `/Library/Developer/CommandLineTools`, select the installed Xcode for your shell first (adjust the path for your installation):

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
```

```sh
xcodebuild -project Posty.xcodeproj -scheme Posty -configuration Debug -derivedDataPath DerivedData build
```

Local Debug and Release builds use the same Developer ID Application identity for team `JD26ZWJ4WW`, so Keychain trust survives rebuilds and switching between those builds. CI uses ad-hoc signing only for isolated tests; distributed releases use Developer ID signing and Hardened Runtime.

The test scheme sets `POSTY_TESTING=1`, giving each test process a separate Keychain namespace and disabling the real local store, startup windows, and automatic AI startup. Avoid launching ad-hoc builds against your real saved connections.

## Tests

```sh
xcodebuild -project Posty.xcodeproj -scheme Posty -derivedDataPath DerivedData test
```

Database integration tests are opt-in. Start PostgreSQL 14–18 locally and supply its port:

```sh
POSTY_TEST_POSTGRES_PORT=5432 xcodebuild -project Posty.xcodeproj -scheme Posty -derivedDataPath DerivedData test -only-testing:PostyTests/DatabaseIntegrationTests
```

## Security and storage

Connection profiles and their secrets are stored as Keychain records. Saved queries, folders, chat transcripts, chart specifications, workspace restoration, and execution metadata are stored in app-local SQLite. Query result rows are not persisted.

SSH connections use the system OpenSSH client and an embedded askpass helper. Host keys are pinned in Posty's application-support directory and changed keys are rejected.

Posty launches `codex app-server` through the login shell, verifies that Azure is the active provider, and disables AI when the expected provider or models are unavailable. Schema and SQL context can be sent to AI; database values are excluded unless explicitly attached for that request.

## Releases and automation

- **Build and test** runs on pull requests and `main`, then keeps a development app ZIP and test results for seven days. Development artifacts use ad-hoc signing and are not distribution releases.
- **Label pull requests** uses conventional PR titles (`feat:`, `fix:`, `perf:`, `docs:`, `deps:`, `chore:`, `ci:`, `build:`, `refactor:`, `test:`), branch prefixes, and changed paths. `feat!:` or `fix!:` adds `breaking`. Area labels describe the changed code. The labeler reads PR metadata and never executes PR code with write permissions.
- **Draft release notes** updates the next draft after pushes to `main`, grouped by breaking changes, features, fixes, performance, dependencies, documentation, maintenance, and other changes. `skip-changelog` excludes a PR. Labels can be adjusted before merging; review automatically assigned labels when renaming a PR.
- **Release** runs when you publish the draft, or manually for an existing published release. Use a `vMAJOR.MINOR.PATCH` tag. It tests, archives both architectures, signs the app and SSH helper with Developer ID and Hardened Runtime, notarizes, staples, verifies Gatekeeper, uploads the ZIP and SHA-256 checksum, and updates the Homebrew cask for the latest stable release. The signed Xcode archive and notarization result are retained for 30 days. Missing credentials or failed notarization stop publication of binaries.

To ship, open the draft in [GitHub Releases](https://github.com/coryoso/posty/releases), review the version and notes, then publish it. To retry a failed asset build, run **Release** manually with that release tag. A prerelease flagged in GitHub does not update the stable tap.
