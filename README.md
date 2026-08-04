# MacDrop

MacDrop is a free, local-first, MIT-licensed live wallpaper app for macOS Tahoe. It imports videos you own, plays independent wallpapers and playlists on each display, and can optionally register one video with Tahoe's lock-screen wallpaper system.

## Status

MacDrop v1 is under active development. Lock-screen support uses Tahoe's undocumented per-user Aerials data format. It is opt-in, creates backups before every mutation, validates the schema, and provides a Restore action.

## Requirements

- macOS 26 Tahoe
- Xcode 26.x
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```sh
xcodegen generate
xcodebuild -project MacDrop.xcodeproj -scheme MacDrop -configuration Debug build
```

Run `scripts/verify.sh` for parsing, metadata validation, project generation, and tests when the full Xcode toolchain is available.

## Features

- Managed local video library with transactional MP4, MOV, and M4V imports
- Independent wallpaper or timed playlist assignments per display
- Sequential and non-repeating shuffle playback
- Menu-bar playback and switching controls
- Fullscreen/occlusion, sleep, battery, and thermal-aware playback policy
- Opt-in Tahoe lock-screen registration with schema validation, SHA-256 backups, rollback, health checks, and Restore
- Local redacted diagnostics export

MacDrop always mutes wallpaper audio and performs no network requests.

The app is intentionally not sandboxed because opt-in lock-screen integration updates files under `~/Library/Application Support/com.apple.wallpaper`. It never writes to `/System` or requests Accessibility or Screen Recording access.

## Privacy

MacDrop has no accounts, analytics, telemetry, advertisements, or network services. Imported video remains on your Mac.

## License

MIT. See [LICENSE](LICENSE).
