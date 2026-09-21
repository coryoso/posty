# Posty

Posty is a native PostgreSQL client for macOS. Connect to a database, browse its tables and schema, run SQL, edit rows, and export results from one workspace.

Posty is in early development. It requires **macOS 26 or newer** and runs on Apple silicon and Intel Macs.

## Install

### Homebrew

```sh
brew tap coryoso/homebrew https://github.com/coryoso/homebrew.git
brew install --cask coryoso/homebrew/posty
```

If Homebrew asks you to trust this third-party cask, review it and run `brew trust --cask coryoso/homebrew/posty`, then repeat the install command.

To update an installed copy:

```sh
brew update
brew upgrade --cask coryoso/homebrew/posty
```

### Download the app

Download `Posty-<version>.zip` from [Releases](https://github.com/coryoso/posty/releases/latest), unzip it, and move **Posty.app** into **Applications**. Release builds are signed and notarized by Apple. You do not need Xcode or a GitHub account to use them.

## Getting started

1. Open Posty and choose **New Connection**. Enter the host, port, database, username, and password, or import a PostgreSQL connection URL.
2. Choose the appropriate TLS settings. If your database is reached through a jump host, configure the SSH connection as well. Check the host fingerprint before trusting a new SSH server.
3. Use **Test** to check the connection, **Show Databases** to choose a database, or **Connect** to open the workspace.
4. Browse database objects in the sidebar, or choose **New Query** and run SQL with **⌘ Return**.

## What you can do

- Browse tables and views, inspect columns, constraints, indexes, and DDL, and page through filtered results.
- Insert, edit, and delete rows where the relation supports editing. Changes are staged until you choose **Save**; **Discard** reloads the data without applying them.
- Work with query tabs, save queries into folders, and revisit query history.
- Export table or query results as CSV or JSON, including selected rows.
- Build charts from query results.
- Connect directly or through SSH using a password or an SSH key.

### Optional SQL assistant

The assistant can suggest SQL changes, turn natural-language requests into table filters, and suggest charts. Review proposed SQL before applying or running it.

AI currently requires a separately installed `codex` CLI, an active `azure` provider, and access to both `gpt-5.6-luna` and `gpt-5.6-terra`. This is a specific configuration requirement, not something included with the app. Posty checks it at startup and leaves AI unavailable when it is not configured; browsing, SQL, editing, exports, and manual charts still work.

## Your data

Connection profiles, database passwords, and SSH passwords/passphrases are stored in your macOS Keychain. SSH uses the system OpenSSH client; Posty remembers trusted host keys and rejects changed keys.

Saved queries, folders, chat transcripts, chart definitions, workspace state, and execution metadata are stored locally in `~/Library/Application Support/Posty/`. Query result rows are not automatically persisted. SQL text, chat text, and files you explicitly export can contain database information.

When you use AI, schema and SQL context may be sent to your configured provider. Database values are excluded unless you explicitly attach them to that request.

## Build and run from source

You need macOS 26+, a full Xcode 26+ installation, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app uses Swift 6, SwiftUI/AppKit, PostgresNIO, and NIOSSL; Xcode resolves the Swift packages during the build.

```sh
brew install xcodegen
git clone https://github.com/coryoso/posty.git
cd posty
xcodegen generate
```

If `xcode-select -p` points to Command Line Tools rather than Xcode, select your Xcode installation for this shell (adjust the path if needed):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

### Run manually

For a local development build without the maintainer's distribution certificate:

```sh
xcodebuild -project Posty.xcodeproj -scheme Posty \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build
open DerivedData/Build/Products/Debug/Posty.app
```

This uses ad-hoc signing. Such builds can ask for Keychain access again after a rebuild or when switching from the released app. For regular development, use a consistent Apple Development identity and your own team instead:

```sh
xcodebuild -project Posty.xcodeproj -scheme Posty \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

Replace `YOUR_TEAM_ID` with your development team and ensure its signing certificate is installed. You can also open `Posty.xcodeproj` in Xcode, configure local signing for the app and SSH helper, and run the **Posty** scheme on **My Mac**. Keep personal signing changes out of pull requests.

### Run tests

```sh
xcodebuild -project Posty.xcodeproj -scheme Posty \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= test
```

The test scheme isolates Keychain records and disables the normal app startup and local store. The default suite does not require a running database or AI service.

The optional database integration test uses PostgreSQL 14–18 on `localhost`, database `postgres`, user `postgres`, with no password. Use a disposable local test database: the test creates and removes tables, types, and domains in its `public` schema.

```sh
POSTY_TEST_POSTGRES_PORT=5432 xcodebuild -project Posty.xcodeproj -scheme Posty \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  test -only-testing:PostyTests/DatabaseIntegrationTests
```

The live AI test is also opt-in, using `POSTY_CODEX_SMOKE=1` with the test command and the AI configuration described above.

## Contributing

Bug reports and focused pull requests are welcome. For a bug report, include your macOS and Posty versions, steps to reproduce it, and the expected behavior. Use anonymized SQL and sample data; remove connection details and credentials from logs and screenshots.

1. Fork the repository and create a branch for your change.
2. Build and run the app locally. Add or update a focused test when changing behavior, then run the relevant tests.
3. If build settings or targets need changes, edit **`project.yml`** and run `xcodegen generate`. Commit the generated project changes with it; the YAML file is the source of truth.
4. Open a pull request describing the problem, your change, and how you checked it. For visible interface changes, include a screenshot with sample data.

Use PR titles such as `feat: add …`, `fix: correct …`, or `docs: explain …`. Automation applies labels and groups merged changes into release notes. CI builds the app and runs tests; its development artifacts are for testing. Install signed releases for everyday use.
