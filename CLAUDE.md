# Scrubble

Dual-platform (macOS / iOS jailbreak) Last.fm scrobbler. Monitors system-wide music playback via the private **MediaRemote** framework and submits scrobbles to Last.fm.

**Bundle ID:** `fr.rootfs.scrubble` | **Prefs Bundle ID:** `fr.rootfs.scrubbleprefs`

## Project structure

```
include/               Headers (shared between platforms)
  Constants.h          BUNDLE_ID, PREFS_BUNDLE_ID, LASTFM_API_URL defines
  Scrobbler.h          Core scrobbling engine interface
  CredentialStore.h    Singleton credential/preference storage
  MetadataFilter.h     Track/artist/album cleanup interface
  ScrubbleMacSettings.h  macOS settings window controller
  ScrubbleUtils.h      Shared static inline utilities (ScrubbleMD5, ScrubbleQueryString)
src/                   Implementation files
  main.m               Entry point (macOS menu bar app / iOS daemon)
  Scrobbler.m          Last.fm API + MediaRemote observer
  CredentialStore.m    Keychain + NSUserDefaults persistence (cached)
  MetadataFilter.m     Regex-based metadata cleanup (Remastered/Live/feat./etc.)
  ScrubbleMacSettings.m  macOS settings GUI (no XIB)
assets/                Icon source files (Scrubble.icns, StatusBarIcon.png, source PNGs)
ScrubblePrefs/         iOS preference bundle (PSListController)
  Resources/           icon.png{,@2x,@3x}, Root.plist, Info.plist
  include/             NSTask.h (rootless helper)
layout/                iOS LaunchDaemon plist + DEBIAN metadata
Makefile               iOS build (Theos, iphone:clang:14.5:14.0)
Makefile.macos         macOS build (clang, app bundle)
entitlements.plist     iOS entitlements (no-sandbox, keychain)
entitlements.macos.plist  macOS entitlements (keychain)
control                Debian package metadata
```

## Build

### macOS
```
make -f Makefile.macos        # -> build/macos/Scrubble.app
make -f Makefile.macos run    # build + open
make -f Makefile.macos clean
```
Compiler: `clang -fobjc-arc -Wno-deprecated-declarations -I${THEOS}/vendor/include -Iinclude`
Frameworks: Cocoa, Security, ServiceManagement, UserNotifications, MediaRemote (private, from `/System/Library/PrivateFrameworks`)
Codesigned ad-hoc with `entitlements.macos.plist`. Icons copied from `assets/` into `Contents/Resources/`.

### iOS (Theos)
```
make package    # builds .deb with Scrubble tool + ScrubblePrefs bundle
```
Target: `iphone:clang:14.5:14.0`. Installs to `/usr/local/libexec/Scrubble`.
Runs as LaunchDaemon (`KeepAlive`, `RunAtLoad`, user `mobile`).
Supports rootless jailbreaks (adjusts paths via PlistBuddy).
ScrubblePrefs bundle uses `-Iinclude -I../include` to resolve shared headers from the project root.
Dependencies: `gawk`, `preferenceloader`, `com.opa334.altlist`.

## Architecture

### Key classes

| Class | Role |
|-------|------|
| `Scrobbler` | Core engine. Observes `kMRMediaRemoteNowPlayingInfoDidChangeNotification`, debounces track changes (1s), waits 3.5s for MediaRemote metadata, schedules scrobble at `scrobbleAfter` % of duration, validates track hasn't changed before submitting. Min 30s track duration. Token auto-refresh on HTTP 403 (mobile session only). |
| `CredentialStore` | Singleton. macOS: all creds in Keychain. iOS: NSUserDefaults (except token in Keychain). Caches NSUserDefaults instance. |
| `MetadataFilter` | Regex-driven cleanup applied to track/artist/album before scrobbling. Toggleable via `isMetadataFilterEnabled`. Strips "Remastered", "(Live)", "feat. X", reissue annotations, etc. |
| `ScrubbleMacSettings` | NSWindowController with programmatic UI (no XIB). 450x675 window. OAuth desktop auth flow + mobile session fallback. Layout uses block helpers inside `setupWindow` (no auto-layout). |
| `ScrubbleMenuBarController` | macOS status bar menu (now playing, last scrobbled, open library, enable toggle, launch at login, show notifications, settings, quit). Posts `UNUserNotification` on scrobble success and on scrobble failure; failure notification carries `Retry` / `Copy reason` actions via `SCROBBLE_FAILED` category. |
| `SCRUBRootListController` | iOS PSListController for Settings.app integration. |

### Shared utilities (`include/ScrubbleUtils.h`)
- `ScrubbleMD5(NSString *)` — MD5 hash for Last.fm API signatures
- `ScrubbleQueryString(NSDictionary *)` — URL query string builder
- Static inline functions, no extra .m file or Makefile changes needed

### MediaRemote symbol gates
- `SCRMediaRemoteSymbolsAvailable()` (declared in `Scrobbler.h`) — `dlsym` probe of `MRMediaRemoteGetNowPlayingInfo` and `MRMediaRemoteRegisterForNowPlayingNotifications` at launch. If either is missing, `mediaRemoteAvailable` static in `main.m` is set to `NO` and `initScrobbler` becomes a no-op.
- `MRMediaRemoteUnregisterForNowPlayingNotifications` is loaded via `dlsym` at first call (also in `Scrobbler.m`). If absent, the unregister path silently no-ops — Foundation-side observer is still removed.

### Platform conditional compilation
All files use `#if TARGET_OS_OSX` / `#else` extensively. The iOS path has a secondary `#ifdef JAILED` for a shake-gesture credential UI (currently disabled via `//#define JAILED`).

### Data flow
1. MediaRemote fires `kMRMediaRemoteNowPlayingInfoDidChangeNotification`
2. `Scrobbler.musicDidChange:` filters by originating notification type + app bundle ID
3. After 3.5s delay (for Apple Music MediaRemote latency), queries `MRMediaRemoteGetNowPlayingInfo()` for track/artist/album/duration
4. Applies `MetadataFilter` if enabled, then calls `track.updateNowPlaying` immediately
5. Schedules `track.scrobble` at `duration * scrobbleAfter` seconds
6. Verification block re-queries MediaRemote and drops the scrobble if the current track no longer matches
7. Cancels pending scrobble if playback pauses (`SCRPlaybackRateIsZero` check on content item KVC) or track changes
8. On scrobble HTTP 200: posts `ScrubbleTrackScrobbledNotification` (UNNotification + menu bar update)
9. On scrobble non-200 / non-403: posts `ScrubbleScrobbleFailedNotification` with `track/artist/album/timestamp/reason`. The menu bar shows a UNNotification with `Retry` (resubmits) and `Copy reason` (copies the failure string to NSPasteboard) actions.
10. On scrobble HTTP 403: `tokenExpired` is called inline from `requestLastfm:` — clears token, reloads via mobile session if a password is available, otherwise logs and requires manual re-auth.

### Launch at Login
- macOS 13+: Uses `SMAppService.mainAppService` (ServiceManagement framework)
- macOS 11-12: Falls back to writing a LaunchAgent plist at `~/Library/LaunchAgents/fr.rootfs.scrubble.plist`
- Both managed via the `isLaunchAtLoginEnabled` helper and toggle in the status bar menu

### IPC
- Darwin notification `fr.rootfs.scrubbleprefs-updated` — posted by settings, observed by main process to reload prefs

## Last.fm API

- Base URL: `LASTFM_API_URL` (`https://ws.audioscrobbler.com/2.0/`) defined in `Constants.h`
- All requests signed with MD5: sorted params concatenated + api_secret (via `ScrubbleMD5`)
- Session token stored via `CredentialStore` (Keychain, service `fr.rootfs.scrubble`, account `token`)
- Methods used: `auth.getToken`, `auth.getSession`, `auth.getMobileSession`, `track.updateNowPlaying`, `track.scrobble`
- Token auto-refreshes on HTTP 403 (mobile session only; OAuth requires manual re-auth)
- `requestLastfm:` always calls its completion on completion (success and non-200 alike — except 403 which short-circuits to `tokenExpired`); callers gate on `response.statusCode == 200`

### Authentication (two methods)
1. **Desktop Auth / OAuth (recommended, macOS)**: `auth.getToken` → browser auth → `auth.getSession`. No password stored. Session key is permanent. Managed in `ScrubbleMacSettings` via "Authorize with Last.fm" / "Complete Authorization" buttons. Both methods funnel through `-postLastfm:completion:`.
2. **Mobile Session (fallback)**: `auth.getMobileSession` with username + password. Used when password is available. Auto-refreshes on 403. Used by iOS and as macOS fallback. Also reachable via "Test Login" in the settings window.

## Conventions

- **ARC** throughout (`-fobjc-arc`)
- Atomic properties on Scrobbler for thread safety
- `dispatch_block_create` + `dispatch_block_cancel` for cancellable scrobbles; the `-cancelPendingScrobble` helper centralizes the cancel-and-nil pattern
- Weak self captures in blocks to avoid retain cycles
- Singleton via `dispatch_once`
- No storyboards/XIBs — all UI is programmatic. `ScrubbleMacSettings.setupWindow:` uses local block helpers (`addCheckbox`, `addField`, `addButton`, `addLabel`) over a `__block CGFloat y` cursor to keep frame math out of the layout body.
- Log prefix: `[Scrubble]`. Natural-prose messages, no structured `event=k v` grammar.
- Numeric constants use `#define NAME_IN_CAPS` (e.g. `TRACK_INFO_DELAY`, `MIN_SCROBBLE_DURATION`); MediaRemote string keys come from the framework directly via `(__bridge NSString *)kMRMediaRemoteNowPlayingInfo*`, never re-declared locally.
- Supported macOS apps hardcoded in `kSupportedApps()`: Apple Music, VLC, foobar2000
- iOS app filtering via AltList (`ATLApplicationListMultiSelectionController`)

## Known quirks

- JAILED mode's save handler is incomplete (no-op after reading text fields)
- Ad-hoc codesigning (`codesign --sign -`) gives a different signature on every rebuild, so the macOS Keychain prompts on every relaunch by default. Whitelisting the binary in `Keychain Access.app → Access Control → "Always Allow"` is one workaround; signing with a stable identity (self-signed cert or Developer ID) is the proper fix.
