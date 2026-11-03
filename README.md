# Rushz

A small SwiftUI music player for iPhone that plays audio from YouTube Music.
Search, home feed, radio-style up-next queue, playlists, library, history,
lyrics, background playback and optional Google sign-in.

> **Personal-use project.** Rushz is not affiliated with or endorsed by YouTube
> or Google, and it uses YouTube's unofficial internal API. That breaks the
> YouTube Terms of Service and App Store Review Guideline 5.2.3, so it cannot be
> published on the App Store. Build it for your own device at your own risk, and
> it may stop working whenever YouTube changes its API.

## Requirements

- macOS with Xcode 16 or later
- An iPhone on iOS 17 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple ID. A free one works, with the 7-day limit described below.

## Build and run

1. Clone the repo and generate the Xcode project:
   ```sh
   git clone https://github.com/<you>/rushz.git
   cd rushz/App
   xcodegen generate
   ```
2. Open `App/project.yml` and set:
   - `PRODUCT_BUNDLE_IDENTIFIER` to something unique to you, e.g. `com.yourname.rushz`
     (and the tests target to `com.yourname.rushz.tests`).
   - `DEVELOPMENT_TEAM` to your team ID (Xcode > Settings > Accounts > your
     Apple ID > Team; the ID is also shown in the Signing & Capabilities tab).

   Run `xcodegen generate` again after editing.
3. Open `App/Rushz.xcodeproj`, pick your iPhone as the destination and press Run.
4. First install only: on the iPhone, go to Settings > General > VPN & Device
   Management and trust your developer certificate. Also turn on
   Settings > Privacy & Security > Developer Mode if iOS asks for it.

## Staying installed with a free Apple ID

Apps signed with a free Apple ID stop opening after 7 days. `scripts/renew.sh`
rebuilds and reinstalls the app before that happens. Your songs, playlists and
sign-in are kept, because the bundle ID doesn't change.

1. Find your iPhone's identifier: `xcrun devicectl list devices`.
2. Try it once by hand:
   ```sh
   RUSHZ_DEVICE_UDID=<identifier> RUSHZ_BUNDLE_ID=com.yourname.rushz scripts/renew.sh --force
   tail ~/Library/Logs/Rushz/renew.log
   ```
3. Run it automatically every 6 hours: edit the paths and identifier in
   `scripts/com.example.rushz.renew.plist`, then
   ```sh
   cp scripts/com.example.rushz.renew.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.example.rushz.renew.plist
   ```

The script only rebuilds when fewer than 2 days of signing are left. The phone
has to be reachable, either plugged in or on the same Wi-Fi with
"Connect via network" ticked in Xcode > Window > Devices and Simulators. You
get a macOS notification if a renewal fails.

If macOS blocks the script with "Operation not permitted", keep the repo out of
`~/Desktop` and `~/Documents`, which launchd agents can't read by default, or
give `/bin/bash` Full Disk Access.

A paid Apple Developer account ($99/year) signs builds for a year and makes the
script unnecessary.

## Tests

```sh
cd App
xcodebuild test -project Rushz.xcodeproj -scheme Rushz \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The parser tests run against trimmed, signed-out YouTube Music responses in
`App/Tests/Fixtures`, so a change in YouTube's response format shows up as a
failing test.

## Layout

```
App/
  project.yml          XcodeGen spec (the .xcodeproj is generated, not committed)
  Sources/             the app (SwiftUI)
  Tests/               unit tests and response fixtures
  Packages/YouTubeKit/ vendored YouTubeKit with local changes (see VENDORED.md)
scripts/
  renew.sh             7-day re-signing for free Apple IDs
```

## Credits

Stream extraction uses [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)
by Alexander Eichhorn (MIT), vendored under `App/Packages/YouTubeKit`.

## License

MIT, see [LICENSE](LICENSE).
