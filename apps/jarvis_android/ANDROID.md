# JARVIS Android 0.4.68 (source)

Android client for the JARVIS server. Package: `cc.odn.jarvis_android`; version code: **100**; release ABI: **arm64-v8a**. The native iOS client is maintained separately in `ios/`.

## Changes

- Recover native audio output after a platform write failure instead of poisoning later playback.
- Separate voice reasoning settings from text-chat settings; follow server voice defaults unless explicitly overridden.
- Retain selected voices through server-side speech model aliases.
- Restore full final transcripts and preserve interrupted-message status in conversation history.
- Show audio preparation and playback states honestly; record playback counters and cancellation sources without recording conversation text or audio.
- Preserve the existing foldable layouts and motion fixes.

## Verify and build

With Flutter 3.47.7 (Dart 3.13.5) and the Android SDK installed:

```sh
cd apps/jarvis_android
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

For a signed release, set `JARVIS_SIGNING_PROPERTIES` to a private properties file containing `storeFile`, `storePassword`, `keyAlias` and `keyPassword`. Keep the file and keystore outside this repository. Existing installations require the same signing key. The published APK uses the existing personal release certificate; building without that private key does not produce an upgrade-compatible signed APK.

The default server is `https://jarvis.odn.cc`; override it at build time using `--dart-define=JARVIS_SERVER=https://your-server.example`. No account password, API token or signing material is included. See [BUILD-SPARK.md](BUILD-SPARK.md) for the existing isolated Spark build environment.

## Validation

231 widget/unit tests and static analysis passed on this source snapshot. Additional real-font diagnostics confirm animation state continuity and zero card-height jumps (within floating-point precision). Four folding layouts were captured and inspected. These checks do not certify real-device audio or animation frame rates.

## Install

Download an APK from the GitHub Releases page and install over the existing app. Source version 0.4.68 is newer than the currently published 0.4.62 APK; this source sync does not create a new APK release. Do not uninstall or clear app data to upgrade.
