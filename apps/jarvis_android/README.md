# JARVIS app (iOS, Swift)

The phone app for the self-hosted JARVIS voice assistant: chat, voice calls, image and video generation, with a
Chinese UI. It is a native Swift app (UIKit + SwiftUI, Liquid Glass) built for the foldable iPhone Duo and the iPhone
Pro Max (see [IOS.md](IOS.md)).

It talks to a JARVIS server that you run yourself (see the repository's top-level README and `deploy/jarvis/`). The
app has no built-in server: set the address in `ios/Runner/NativeApp.swift` (`NativeApp.server`, a placeholder by default).
The sign-in is the account of that server.

## Build and run

```
cd apps/jarvis_android/ios
xcodebuild -project Runner.xcodeproj -scheme Runner -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

See [IOS.md](IOS.md): signing with your own team, the bundle id to change, TestFlight upload.

## Tests

```
cd apps/jarvis_android/ios/JarvisCore && swift test      # the logic layer: sessions, streaming, persistence, backup, voice
ios/tools/smoke.sh                                       # simulator screenshots of every page, compared with a baseline
```

## Notes

- [IOS.md](IOS.md): build and release steps, debug flags.
- [DESIGN.md](DESIGN.md), [FOLDABLE.md](FOLDABLE.md): design notes and foldable-screen rules.
- The privacy-policy and support-contact values are in `ios/JarvisCore/Sources/JarvisCore/AppInfo.swift` (empty by default:
  the rows that depend on them stay hidden).
- No account, token or certificate is stored in the project.

## License

Apache License 2.0, like the rest of the repository; see the top-level `LICENSE` and `NOTICE`.
