# JARVIS Android 0.4.62

Android client for the JARVIS server. Package: `cc.odn.jarvis_android`; version code: **94**; release ABI: **arm64-v8a**. The native iOS client is maintained separately in `ios/`.

## Changes

- Keep the live welcome animation across rotation, unfolding and docked-sidebar changes; a new conversation still gets a new random scene.
- Keep card typography and height stable while opening, closing or dragging the sidebar.
- Preserve the expanded-landscape vertical welcome composition and the cover-landscape composition without suggestion cards.
- Include the current attachment retry feedback, long filenames, and compact completed-work entry.

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

211 widget/unit tests and static analysis passed on the release source. Additional real-font diagnostics confirm animation state continuity and zero card-height jumps (within floating-point precision). Four folding layouts were captured and inspected. These checks do not certify real-device audio or animation frame rates.

## Install

Download `JARVIS-0.4.62-arm64-v8a.apk` from the GitHub Release and install over the existing app. Do not uninstall or clear app data to upgrade.
