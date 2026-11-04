# JARVIS on iOS (iPhone Duo)

A native Swift app (UIKit + SwiftUI, Liquid Glass) in `ios/`. The logic layer is the Swift package `ios/JarvisCore`
(compiled into the app target and tested with `swift test`); the pages are in `ios/Runner`. The Flutter version was removed
on 2026-11-01 (a rollback archive is kept outside the repository).

## Build and run

```
cd ios
xcodebuild -project Runner.xcodeproj -scheme Runner -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build            # simulator
xcodebuild -project Runner.xcodeproj -scheme Runner -sdk iphoneos -configuration Release \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM_ID> build   # a phone
xcrun devicectl device install app --device <DEVICE_UDID> <...>/Release-iphoneos/Runner.app
(cd JarvisCore && swift test)                                    # logic tests
tools/smoke.sh                                                   # simulator screenshots of every page, compared with a baseline
```

- Bundle ID `com.example.jarvis`; change it (and the team) if you build under your own account. An explicit App ID belongs to one team.
- Minimum iOS 18. The Liquid Glass pieces need iOS 26+ and fall back to blur/tinted buttons below that. The foldable features
  (vertical bar, hinge) need iOS 27.1+ and are guarded by `#available`.
- `ios/tools/smoke.sh` drives the debug flags `JARVIS_*` (see `Runner/NativeChatPreview.swift`, `NativeChat.swift`);
  they exist only in Debug builds. `ios/tools/VOICEOVER_CHECKLIST.md` is the VoiceOver walk-through.

## Release to TestFlight

1. **Raise the build number first**: `CURRENT_PROJECT_VERSION` in `ios/Runner.xcodeproj/project.pbxproj` (now 41; the version is
   `MARKETING_VERSION` 0.4.6). App Store Connect rejects a number that is not above every earlier upload of the same version; a new
   version number needs a new Beta App Review for external testers.
2. Archive with the paid team and upload:
   ```
   xcodebuild -project Runner.xcodeproj -scheme Runner -configuration Release -destination 'generic/platform=iOS' \
     -archivePath build/Jarvis.xcarchive -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic archive
   xcodebuild -exportArchive -archivePath build/Jarvis.xcarchive -exportPath build/upload \
     -exportOptionsPlist <copy of ios/ExportOptions.plist with the real team id> -allowProvisioningUpdates
   ```
   `destination` is `upload` in `ExportOptions.plist`; use `export` for a dry run that only makes a signed `.ipa`. The upload uses the
   Apple ID signed in to Xcode (Settings > Accounts must contain the account that owns the paid team).
3. In App Store Connect > the app > TestFlight: wait for processing, answer export compliance with "no non-exempt encryption"
   (`ITSAppUsesNonExemptEncryption = false`), add the build to a group; external groups need Beta App Review.
4. **A build expires 90 days after upload.**
