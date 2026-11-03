# Public browser voice regression

`public_voice_regression.cjs` adapts the upstream long-reply checks from
`038224a` and `7f59e73` to this deployment's public browser playback path.
It exercises the existing deployed page without changing its buffering policy.

Run with Node and Playwright installed:

```bash
PLAYWRIGHT_MODULE=/path/to/playwright \
OUT=/path/to/results.json \
node tools/spark/jarvis/public_voice_regression.cjs
```

Defaults: `JARVIS_URL=http://127.0.0.1:8190/voice`, `MAX_START_MS=3000`.
If redirected to login, credentials are read privately from `JARVIS_AUTH_DIR`
(default `~/jarvis/public`), using `auth.json` and `登录信息.txt`.
Do not run against an untrusted URL. Credentials are never written to the report.
The temporary browser context blocks service workers and uses a fake microphone.
Browser and voice session are closed on completion or failure.

The test warms one reply, plays a long Chinese story, cancels a fixed read-aloud reply
while its response and playback are active, then requests a short recovery reply.
It checks:

- Long reply and recovery start within 3 seconds (configurable).
- Long reply contains at least 15 seconds of PCM audio and starts before text completion.
- No long-reply scheduler underrun or detected output render/delivery gaps over the reply (up to 600 seconds; response and playback each have a separate 180-second wait timeout). Recorder spans match both connection number and item ID.
- Cancellation status and removal of the interrupted reply's buffered/live audio.
- Recovery produces a completed spoken response; browser reports no page errors.

Missing measurements fail the test. The JSON includes timestamps, per-turn audio
counts, output gap measurements, all checks and any harness failure; exit status
is nonzero on failure. Warmup and intentional interruption are excluded from the
long-reply gap checks. No models, media jobs or production services are restarted.
Generated replies can vary: a short story, a reply without audio, or an already-completed interruption target
fails validation rather than being counted as a pass.

This is a text-triggered real voice playback test in headless Chrome. It does not
validate microphone transcription, acoustic echo cancellation, physical Bluetooth
hardware or the user's PC audio driver. Programmatic cancellation tests the
existing browser interruption path, not microphone/VAD detection.

Assessment unit tests:

```bash
node --test tests/public_voice_regression_test.cjs
```
