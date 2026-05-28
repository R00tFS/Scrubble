# Scrubble

A Last.fm scrobbler for **macOS** and **jailbroken iOS**. Watches Apple's private `MediaRemote` framework, so any app that registers with the Now Playing system (Apple Music, VLC, foobar2000, the iOS Music app, …) gets scrobbled automatically.

> [!WARNING]
> On recent macOS versions, Apple has locked down MediaRemote behind some entitlements. As my device is on macOS Sequoia, Scrubble remain untested on these version.

## Features

- OAuth (browser) or username + password auth, token stored in the Keychain
- Configurable scrobble threshold (default 70 % of duration, 30 s minimum)
- Per-app allowlist (macOS: hardcoded list; iOS: any app via AltList)
- Metadata cleanup — strips "Remastered", "(Live)", "feat. X", reissue tags
- macOS menu bar UI; failed scrobbles surface as a notification with `Retry` / `Copy reason` actions

## Requirements

Xcode command-line tools + Theos (with patched `MediaRemote.h` in `${THEOS}/vendor/include`). A Last.fm API key + secret from <https://www.last.fm/api/account/create>.

## Build

### macOS

```sh
make -f Makefile.macos              # → build/macos/Scrubble.app
make -f Makefile.macos run          # build and launch
```

### iOS

```sh
make package                        # → packages/fr.rootfs.scrubble_<ver>_iphoneos-arm.deb
```

Install the `.deb` via your jailbreak's package manager. The daemon installs to `/usr/local/libexec/Scrubble` and runs as `mobile` under launchd. Rootless-aware.

## Codesigning (macOS)

The default `Makefile.macos` ad-hoc-signs with `--sign -`. That works but means macOS will prompt for Keychain access on every rebuild — the signing identity changes each time and Scrubble's keychain items don't recognise the new binary.

### Apple Development cert + team-prefixed entitlement

The `com.apple.security.keychain-access-groups` entitlement only authorises keychain access without prompts if it's prefixed with your **Team ID**, and only if the binary is signed by a cert whose Team ID matches that prefix.

The committed `entitlements.macos.plist` deliberately ships **without** a team prefix so it doesn't bake one developer's identity into the repo:

```xml
<key>com.apple.security.keychain-access-groups</key>
<array>
    <string>fr.rootfs.scrubble</string>
</array>
```

For local builds, override it with a gitignored copy that adds your team prefix. Create `entitlements.macos.local.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.keychain-access-groups</key>
    <array>
        <string>XXXXXXXXXX.fr.rootfs.scrubble</string>
    </array>
</dict>
</plist>
```

Replace `XXXXXXXXXX` with your Team ID (find it via `security find-identity -v -p codesigning`, in parentheses after your cert name; or by signing once and reading `TeamIdentifier` from `codesign -dv`).

Then re-sign after each build:

```sh
codesign --force --deep --sign "Apple Development" \
    --entitlements entitlements.macos.local.plist \
    build/macos/Scrubble.app
```

`"Apple Development"` matches the first cert of that type in your login keychain. Substitute `"Developer ID Application"` if you have one, or use your cert's SHA-1 hash if you need to disambiguate.

If you already have stale keychain items from an earlier ad-hoc-signed build, wipe them so they get recreated under the new identity:

```sh
for a in token username password apiKey apiSecret; do
    security delete-generic-password -s fr.rootfs.scrubble -a "$a" 2>/dev/null
done
```

## Usage

1. Grab an API key + secret at <https://www.last.fm/api/account/create>.
2. Launch Scrubble, open Settings.
3. Paste the key + secret. On macOS, click **Authorize with Last.fm**, complete in browser, click **Complete Authorization**. Or use the username + password flow.
4. Pick which apps to watch.
5. Play music.

On iOS, preferences live in **Settings → Scrubble**; changes propagate to the daemon without restarting it.

## How it works

`Scrobbler` observes `kMRMediaRemoteNowPlayingInfoDidChangeNotification`. After a 5 s grace period (lets MediaRemote populate metadata), it checks `MRMediaRemoteGetNowPlayingApplicationIsPlaying` — if nothing's actually playing the notification is dropped (this catches stale "now playing" data from apps that just closed). Otherwise it reads the now-playing info, fires `track.updateNowPlaying`, and schedules `track.scrobble` for `duration * scrobbleAfter` seconds later. When the scheduled scrobble fires, it re-verifies the current track tuple against MediaRemote **and** re-checks `IsPlaying`, so paused or skipped tracks are dropped. 403s trigger an automatic mobile-session re-auth if a password is stored; everything else surfaces as the failure notification.

## Project layout

```
include/                Shared headers
src/                    Implementation
  main.m                Entry point — macOS NSApp / iOS daemon
  Scrobbler.m           MediaRemote observer + Last.fm client
  CredentialStore.m     Keychain + NSUserDefaults persistence
  MetadataFilter.m      Regex cleanup of track titles
  ScrubbleMacSettings.m macOS settings window
ScrubblePrefs/          iOS preference bundle
assets/                 Icons
layout/                 iOS LaunchDaemon plist + Debian metadata
Makefile                iOS build (Theos)
Makefile.macos          macOS build (clang)
```

