# Development

## Setup

1. **Install tools**: Xcode 26 or later and XcodeGen.
   ```bash
   brew install xcodegen
   ```
2. **Add your keys**: copy the template and fill it in. `Config/Secrets.xcconfig` is gitignored; never commit it.
   ```bash
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
   | Key | Required | Notes |
   |---|---|---|
   | `TMDB_READ_TOKEN` | yes | TMDB → Settings → API → *API Read Access Token* (the long JWT, not the short API key) |
   | `TRAKT_CLIENT_ID` | for Top 250 and box office | trakt.tv/oauth/applications → New Application |
   | `OPENSUBTITLES_API_KEY` | optional | opensubtitles.com → API consumers; users can also enter their own |
3. **Generate the project** (again after every pull or `project.yml` change):
   ```bash
   xcodegen generate
   open AMDB.xcodeproj
   ```
4. **Signing**: `project.yml` sets `DEVELOPMENT_TEAM` for every target. Change it to your own team ID, or set it in
   Xcode's Signing & Capabilities (Xcode keeps it only until the next `xcodegen generate`).

### Targets

| Scheme / target | Platform | Bundle ID |
|---|---|---|
| **AMDB** | iPhone, iPad | `app.amdb.ios` |
| AMDBWidgets | iOS extension | `app.amdb.ios.widgets` |
| **AMDBTV** | Apple TV | `app.amdb.ios` (same ID: one App Store listing, shared iCloud Keychain) |
| AMDBTopShelf | tvOS extension | `app.amdb.ios.topshelf` |
| AMDBUITests, AMDBTVUITests | UI tests | |

All four app/extension targets use the App Group `group.app.amdb`.

## Demo mode

Launch with **`-demo`** to run on built-in sample data (no accounts, no network for put.io/TMDB). Add
**`-demoScreen <name>`** to open a screen directly:

| App | Screens |
|---|---|
| iOS | `title`, `show`, `versions`, `search`, `library`, `movies`, `upcoming`, `person`, `collection`, `surprise`, `settings`, `chart`, `player` |
| tvOS | `title`, `show`, `person`, `collection`, `surprise`, `chart`, `upcoming`, `library`, `search`, `settings`, `movies`, `tvshows`, `player` |

`-demoSlowLibrary` slows TMDB matching so you can see the first-launch loading row.

From the command line:
```bash
xcrun simctl launch booted app.amdb.ios -demo -demoScreen title
```

## Testing

**Unit tests** (Swift Testing, about 260 tests across `AMDBCore` and `AMDBKit`):
```bash
cd AMDBCore && swift test
```
Clients are tested against canned HTTP responses (`StubTransport`); models against in-memory fakes
(`Tests/AMDBKitTests/Support/Fakes.swift`).

**UI tests** (XCUITest, demo mode):
```bash
xcodebuild -project AMDB.xcodeproj -scheme AMDB \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test -only-testing:AMDBUITests/ComingUpUITests

xcodebuild -project AMDB.xcodeproj -scheme AMDBTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' test -only-testing:AMDBTVUITests
```
Notes:
- Run one simulator at a time; parallel runs on the same build folder can hang.
- Some tests need a signed-in put.io account (they skip themselves otherwise) or Apple Intelligence (Ask AMDB).
- Set `TEST_RUNNER_SHOTS_DIR=/some/folder` to save the screenshots tests take.
- Offline downloads don't work in the Simulator; test them on a device.

## Releasing (TestFlight)

1. **Bump the build number** in `project.yml` (`CURRENT_PROJECT_VERSION`; `MARKETING_VERSION` is the user-facing
   version), then `xcodegen generate`. Every target reads both values.
2. In Xcode: close and reopen `AMDB.xcodeproj` if it was open, **Product → Clean Build Folder**, then **Product →
   Archive** with the **AMDB** scheme (any iOS device), and again with **AMDBTV** (any tvOS device).
3. Organizer → **Distribute App** → App Store Connect → Upload.
4. In App Store Connect → TestFlight, add the build to a group. External groups need Beta App Review and the Test
   Information page (description, feedback email, privacy policy URL, reviewer sign-in).

Requirements already handled in `project.yml`:
- `ITSAppUsesNonExemptEncryption = NO` (no export-compliance questions).
- `UIRequiredDeviceCapabilities = arm64` for the tvOS app and Top Shelf (App Store validation rejects tvOS binaries
  without it).
- Privacy manifest: `App/iOS/PrivacyInfo.xcprivacy`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Archive shows the old build number | Close and reopen the project after `xcodegen generate`; Clean Build Folder |
| "Requires a development team" | Set `DEVELOPMENT_TEAM` in `project.yml` and regenerate |
| `Mkdtemp … DerivedData` / builds fail oddly | The disk is full. Free space (DerivedData, `build/`, old simulators: `xcrun simctl delete unavailable`) |
| Simulator stuck on "Connecting to display" | With Xcode 27, simulators open in **DeviceHub** (Xcode → Open Developer Tool). Remove old Xcode versions whose Simulator.app gets opened instead |
| Edits to an `Info.plist` disappear | Those files are generated from `project.yml`; change the `info:` properties there |
| Top Shelf is empty | Open the TV app once; it writes the Top Shelf data on launch and whenever you leave it |

## Code conventions

- Swift 6 strict concurrency; UI state in `@Observable @MainActor` models; services behind protocols in AMDBKit.
- Logic that can be tested without UI goes in the package with a test; app targets stay thin.
- New files in `App/` need `xcodegen generate` before Xcode sees them.
- Never commit secrets; check `git status` for `Config/Secrets.xcconfig` (it's ignored, but stay careful).
