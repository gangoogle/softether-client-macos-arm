# softether-client-macos-arm

Native macOS ARM64 menu bar client for SoftEther VPN.

This project uses Swift Package Manager and AppKit. It does not use the old
Python backend, shell web server, or browser UI at runtime.

## Layout

- `Package.swift` - Swift Package entrypoint.
- `Sources/` - AppKit menu bar app, panel UI, config, and runtime control.
- `scripts/build_app.sh` - Builds and assembles `SoftEtherVPN.app`.
- `bin/` - Required ARM64 SoftEther runtime files used by the app bundle.
- `ReadMeFirst_*` and `Authors.txt` - SoftEther upstream license and notice files.

Generated local artifacts such as `.build/` and `SoftEtherVPN.app/` are ignored
for source control and can be regenerated.

## Build

```bash
./scripts/build_app.sh
```

The script runs `swift build -c release --arch arm64` and assembles:

```text
SoftEtherVPN.app
```

## Runtime Behavior

The app bundle contains a clean runtime template. On launch, the app copies the
runtime into:

```text
~/Library/Application Support/SoftEtherVPN/Runtime
```

SoftEther mutable files such as `vpn_client.config`, pid files, control files,
and logs are written there instead of inside the signed `.app` bundle.

## Configuration

Editable configuration is stored in `UserDefaults`; the VPN password is stored
in Keychain. A local `.env` file can still be imported once during development,
but real credentials must not be committed.

## macOS TAP Requirement

This client expects `/dev/tap0` on macOS. If `/dev/tap0` is missing, the app can
start and show status, but connecting will fail with an actionable TAP error.
