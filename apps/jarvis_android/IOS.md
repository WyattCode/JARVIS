# JARVIS on iOS (iPhone Duo)

The same Flutter code base runs on iOS. Everything specific to iOS or to the foldable iPhone Duo is gated by
`defaultTargetPlatform == TargetPlatform.iOS` or by `DuoLayoutScope.of(context).isFoldable` (`lib/ui/duo_layout.dart`),
so the Android build behaves as before. The one deliberate exception is the brand: the app name and the on-screen
brand text read `JARVIS` on every platform (Android launcher label included).

## Build and run

```
flutter pub get
flutter build ios --release            # unsigned build check: add --no-codesign
cd ios && open Runner.xcworkspace      # Runner > Signing & Capabilities: choose your own Team
```

- Bundle ID is `com.example.jarvis` (the App Store Connect / TestFlight app); change it if you build under your own account.
  An explicit App ID belongs to one team only: a team that registered it (even a free Personal Team) blocks every other team.
- No team, certificate or secret is stored in the project. `ios/ExportOptions.plist` ships a
  `REPLACE_WITH_YOUR_TEAM_ID` placeholder for TestFlight / App Store uploads.
- Minimum iOS 15. The Liquid Glass buttons need iOS 26+ and fall back to tinted buttons below that.
- The iOS Simulator on a Mac without a microphone refuses voice (AVAudioEngine aborts without an input); set
  `SIMCTL_CHILD_JARVIS_SIM_HAS_MIC=1` when an audio input device is attached.
- Do not test the keyboard or the microphone with the phone attached to a Mac that controls it (Device Hub / remote
  display): the Mac's hardware keyboard replaces the on-screen keyboard and the microphone input is silent.

## What lives where

| Area | Files |
| --- | --- |
| Foldable layout model, side strip, bar metrics | `lib/ui/duo_layout.dart`, `ios/Runner/DuoLayoutBridge.swift` |
| Vertical control strip (native Liquid Glass buttons) | `lib/ui/duo_rail.dart`, `ios/Runner/DuoRailView.swift` |
| Voice: playback and microphone on one engine (echo cancellation) | `ios/Runner/AudioBridge.swift`, `lib/voice/audio_device.dart` |
| Keychain vault, file picker / save / share | `ios/Runner/VaultBridge.swift`, `ios/Runner/FilesBridge.swift` |
| iOS drag behaviour and keyboard dismissal | `lib/ui/ios_scroll.dart`, `lib/ui/keyboard_dismiss.dart` |

Tests: `flutter test` (Dart) and the `RunnerTests` target (Swift). `integration_test/ios_smoke_test.dart` is a device smoke test.

## Release to TestFlight

1. **Raise the build number first.** `pubspec.yaml` has `version: 0.4.6+38`: `0.4.6` is the version, `38` the build number. App Store
   Connect rejects an upload whose build number is not higher than every earlier upload of the same version, so bump the `+N`
   (and the version when features change; a new version number needs a new Beta App Review for external testers) before every upload.
2. `flutter build ios --release --no-pub --config-only`, then archive with the paid team and export/upload:
   ```
   cd ios
   xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -destination 'generic/platform=iOS' \
     -archivePath build/Jarvis.xcarchive -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic archive
   xcodebuild -exportArchive -archivePath build/Jarvis.xcarchive -exportPath build/upload \
     -exportOptionsPlist <copy of ExportOptions.plist with the real team id> -allowProvisioningUpdates
   ```
   `destination` is `upload` in `ExportOptions.plist`; use `export` to only build a signed `.ipa` for a dry run.
   The upload uses the Apple ID signed in to Xcode (Settings > Accounts must contain the account that owns the paid team).
3. In App Store Connect > the app > TestFlight: wait for processing (10 to 30 minutes), answer export compliance with "no
   non-exempt encryption" (matches `ITSAppUsesNonExemptEncryption = false`), add the build to a group. External groups need Beta
   App Review (usually under a day or two): fill in *Test Information* with a working test login, then enable the public link.
4. **A build expires 90 days after upload** (TestFlight shows "90 days left"): upload a new build with a higher build number before then.

Signing notes: the Apple ID that built development apps may be a free Personal Team and cannot upload. The paid team needs the
test device registered (developer.apple.com > Devices; the UDID is in `xcrun devicectl list devices`) before an automatic-signing
archive works, because the archive step wants a development profile that lists a device. Installing the Xcode-signed build on a
device with `xcrun devicectl device install app` is independent of TestFlight; a TestFlight build installed over it replaces it.
