# AMDB

Personal iPad, iPhone and (soon) Apple TV app: browse with TMDB, find releases across chill and direct sources, send them to put.io, and watch with progress synced to put.io.

## Run

```bash
brew install xcodegen          # once
xcodegen generate              # after every pull
open AMDB.xcodeproj            # pick an iPad or iPhone simulator, ⌘R
```

First launch asks for:
1. **put.io**: "Sign in with put.io" (OAuth app "AMDB", client 9877).
2. **TMDB**: an API Read Access Token from themoviedb.org → Settings → API.
3. **chill** (optional): sign in through chill's own page, or paste a chilly token.

### Demo mode

Launch with `-demo` (Xcode: Product → Scheme → Edit Scheme → Arguments) to use built-in sample data without accounts.
Add `-demoScreen title|show|versions|search|library|movies` to open a screen directly.

## Layout

- `AMDBCore/`: Swift package with `AMDBCore` (clients, sources, parser) and `AMDBKit` (app state, view models). Run `swift test` there.
- `App/iOS/`: SwiftUI app.
- `docs/superpowers/`: design spec and implementation plans.
