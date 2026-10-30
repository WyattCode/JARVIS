# JARVIS app (Flutter)

The phone app for the self-hosted JARVIS voice assistant: chat, voice calls, image and video generation, with a
Chinese UI. It is written in Flutter and is built mainly for iOS, including the foldable iPhone Duo (see
[IOS.md](IOS.md)); the Android build is kept working but is not the focus.

It talks to a JARVIS server that you run yourself (see the repository's top-level README and `deploy/jarvis/`). The
app has no built-in server: set the address when you build or run it.

## Run

```
cd apps/jarvis_android
flutter pub get
flutter run --dart-define=JARVIS_SERVER=https://your-server.example.com
```

`JARVIS_SERVER` is the server's address (default `https://jarvis.example.com`, a placeholder). The sign-in is the
account of that server.

## Build for iOS

See [IOS.md](IOS.md): signing with your own team, the bundle id to change, TestFlight upload.

## Tests

```
flutter analyze
flutter test
```

The suite covers layout at several screen sizes and text scales, the iPhone Duo poses, motion (frame by frame),
state and persistence, and the voice session.

## Notes

- [IOS.md](IOS.md): iOS and iPhone Duo specifics, build and release steps.
- [DESIGN.md](DESIGN.md), [FOLDABLE.md](FOLDABLE.md): design notes and foldable-screen rules.
- Optional build-time values: `JARVIS_SERVER` (server address), and the privacy-policy and support-contact values in
  `lib/model/app_info.dart` (empty by default: the rows that depend on them stay hidden).
- No account, token or certificate is stored in the project.

## License

Apache License 2.0, like the rest of the repository; see the top-level `LICENSE` and `NOTICE`.
