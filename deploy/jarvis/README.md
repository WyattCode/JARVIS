# The Jarvis box

## Single-box deployment

The whole of LocalRouter on one GB10 as a systemd user service, from a checkout:

| | |
| --- | --- |
| Chat | `qwen3.8-27b`: TensorFold 1.1.1, Qwen3.8-27B MLX 4-bit + DFlash2 (qualified), priority 100, kept warm |
| Speech to text | `whisper-large-v3-turbo`, priority 90, kept warm, 4 CPU threads (PR #19) |
| Text to speech | `fishaudio/drama-3`: 42 GiB (qualified), priority 95 (the last voice model to go), kept warm, `realtime` lane: the only speech model on the box (Kitten TTS stays in the repo but is not deployed: nothing lists or loads it) |
| Image | `qwen-image-2.1-turbo`, **kept warm** (loaded at start, no idle unload), priority 10: a picture skips the cold load |
| Video | `minimax-h3`, on demand (idle 30 s), priority 0: it evicts the image model to run, and the image model comes back after it |
| Voice | `/voice` and `/v1/realtime` with PR #19's settings: draft after 100 ms, sentence end after 300 ms, greedy transcripts, primed chat, thinking off |

Memory, measured on Spark-01 (2026-10-23), per process: GPU `used_memory` (nvidia-smi) plus host anonymous and shared
memory, sampled every 0.5 s at idle, through a long voice reply (chat and Drama 3 at once), transcription, 1024x1024
and 1664x1664 images and a 25k-token chat. Each server allocates its GPU memory at load, so the peaks are flat. The
bookings in `config.json.in` are each peak plus 256 MiB:

| Model | Measured peak | Booked |
| --- | --- | --- |
| Chat | 18.25 GiB GPU + 0.6 host + its prompt cache in host shared memory (76 KiB a token; capped at 3 GiB, one full 32k context) | 22.1 GiB |
| Drama 3 | 38.3 GiB GPU (the 36.9 GiB weights and the 1.7 GiB codec, nothing else) + 0.6 host | 39.25 GiB |
| Whisper | 2.0 GiB GPU + 1.5 host | 3.75 GiB, + 0.5 working |
| Image | 31.2 GiB at `max_pixels` 1048576 (39.0 GiB before, at `max_side` 1664 squared) | 31.5 GiB |

- **The reserve is 3 GiB.** earlyoom sends SIGTERM below 2% `MemAvailable` (2.4 GiB on this box); the rest covers the
  measured drift of what is not booked (under 0.6 GiB).
- **The image model's scratch** is sized by `max_pixels`, about 4.6 KiB a pixel: 1024x1024, 1360x768 and 768x1360 are
  served, a larger area is refused before it loads, and the PNG bytes are the same as with the larger scratch.
- **A 1024x1024 image** on the warm model evicts nothing; the lowest `MemAvailable` was 11.8 GiB.
- **A 1 s video** (40 GiB) evicts only the image model; the lowest was 11.7 GiB. The image model is back about 30 s
  later.
- **Chat, Drama 3 and Whisper** are never unloaded for an image or a video.

## Install, start, stop

From nothing, every model and then these scripts: `tools/install/bootstrap.sh --profile jarvis-gb10` ([INSTALL.md](../../INSTALL.md)).
Once the models are installed and qualified:

```sh
deploy/jarvis/install.sh   # preflight, build into ~/jarvis/deploy/src/<commit>, config, unit, tailscale serve
deploy/jarvis/start.sh     # start and wait until chat, Drama 3, Whisper and the image model are warm
deploy/jarvis/status.sh    # unit, build, each model's state and memory, URLs
deploy/jarvis/pair.sh      # paired devices: add NAME (a code for the app), token NAME, list, revoke ID|NAME
deploy/jarvis/stop.sh      # stop every model (and a Drama 3 server a killed worker left); --disable: off at boot too
journalctl --user -u localrouter-jarvis -f          # the daemon; models log to ~/jarvis/deploy/data/logs/
tools/jarvis/smoke.sh [--quick]                       # every capability against the live service
```

`install.sh` refuses unless each qualified model's marker says `"qualified": true` and was made from the pins in
this tree. When a model's `pins.json` changes, re-run that model's `qualify.sh` first. Re-running `install.sh` on a
new commit builds it and restarts the running service onto it, once no voice call is open (`voice_sessions` in
`/v1/tools`; it waits up to `IDLE_WAIT_S`, 30 min); on the same commit with the same config it changes nothing. The
unit restarts on failure, and lingering keeps it running without a login. `TOOLS` (tool ids) serves a subset;
`BUILD_ONLY=1` only builds.

Settings live in `env.sh`: the paths of the qualified installs, `PORT` (8190) and `HTTPS_PORT` (10443).

## Reaching it

The daemon listens on `127.0.0.1:8190` only. Browsers allow the microphone only in a secure context, so remote use
goes through HTTPS:

- **On the tailnet:** `https://box.tailnet.ts.net:10443`. The voice page is at `/voice`, the API at `/v1`
  and MCP at `/mcp`. `install.sh` sets this up with `tailscale serve` (tailnet only; Spark-01's other serve entries
  are untouched).
- **Without tailscale:** `ssh -N -L 8190:127.0.0.1:8190 user@192.168.1.100`, then `http://127.0.0.1:8190/voice` on
  your machine. Loopback counts as a secure context.

Who may connect is decided by the tailnet (its ACLs) or by who can ssh in. Do not bind the daemon to `0.0.0.0` or a
LAN address: nothing would authenticate the requests.

## Pairing

`tailscale serve` hands every tailnet peer to the daemon as loopback, so by default any tailnet device can open a voice
session (`/v1/realtime`) or call the MCP tools (`/mcp`). With device pairing on, those two answer only paired devices;
`/voice`, the other `/v1` routes and `/v1/files` stay as they are. It is off by default.

```sh
deploy/jarvis/pair.sh add "my phone"     # a code for the app (XXXX-XXXX, 10 minutes, once) and its localrouter:// link
deploy/jarvis/pair.sh token claude-code    # a token now, for MCP clients and scripts (printed once)
deploy/jarvis/pair.sh list                 # id, name, created
deploy/jarvis/pair.sh revoke ID|NAME       # refused from the next request
```

`pair.sh` runs the deployed binary on `$DEPLOY/config.json` and `$DEPLOY/data` (devices in `data/devices.json`, hashes
only); none of it restarts the service. Five wrong codes within 10 minutes discard the pending codes (logged).

To turn it on: pair what you use first, then `PAIRING_REQUIRED=1 deploy/jarvis/install.sh` (it restarts onto
`"pairing": {"required": true}` once no voice call is open). Later installs keep the deployed setting;
`PAIRING_REQUIRED=0` turns it off. Once it is on:

- **The web page** (`/voice`): paste a token (`pair.sh token browser`) into Settings → API key; the page sends it on
  the socket (`?api_key=`) and its API calls.
- **MCP clients**: `claude mcp add --transport http localrouter https://box.tailnet.ts.net:10443/mcp --header
  "Authorization: Bearer <token>"`, or `localrouter mcp-stdio --token <token>` (or `LOCALROUTER_TOKEN`).
- **Smoke and check scripts**: `tools/jarvis/smoke.sh`, `tools/jarvis/mcp_check.py`, `tools/spark/jarvis/voice_e2e.py`
  and `tools/spark/jarvis/model_manager_check.py` send `$LOCALROUTER_TOKEN` when it is set:
  `LOCALROUTER_TOKEN=$(deploy/jarvis/pair.sh token smoke) tools/jarvis/smoke.sh`. `tools/spark/jarvis/client_check.py`
  drives the web page in Chrome and does not set the page's API key: run it with pairing off.

## Validated voice and 15-second video release (2026-11-03)

The server and web sources include worker cancellation propagation, quiet media receipts,
selected-voice warmup, and the matching `localrouter.session.ready` web handshake. The
bridge applies server-owned voice catalog/default revisions, Simplified Chinese and current
Shanghai date context, and prevents URLs, tool payloads and internal prompts from becoming
spoken replies. Speech identity checks keep retries on the selected voice; they detect acoustic
outliers and are not biometric speaker verification.

The tested deployment uses remote Flash-Next chat, local Drama 3/Whisper, local 1K image
generation and MiniMax H3 video up to 15 seconds. The generic installation profile remains
an operator choice: this commit does not install private production configs. To reproduce the
15-second deployment, set `max_seconds: 15` on the GPU video tool and the voice coordinator's
video tool, and `video_limits.max_seconds: 15` on the HTTP bridge. Keep the default request at
5 seconds, preserve voice-model protection and retain the original 5-second configuration.
The web reads the limits from `/v1/models`.

The accepted public test produced a 15.075-second H.264/AAC file at 768x448, 24 fps, with a
clean full-file decode. That sample took about 4 minutes 14 seconds including polling and
download. A concurrent voice reply completed, with first audio packet about 3.03 seconds after
its text request, excluding connection/warmup. These are single-run observations; they do not
measure physical Bluetooth playback or establish a latency guarantee.

`release_templates/` preserves the audited control sources for the five-layer release chain.
They are source templates for the existing private release layout, not a standalone installer.
The top video layer projects restored hashes before checking older guards, retains the shared
release lock through every child, validates inherited lock identity, rejects malformed journals,
and permits interrupted-deployment recovery only for matching known before/after hashes.
Restoration stops consumers before writing configuration and records progress durably.
Keep each generated manifest, config stage, original backup and journal together in the private
release directory; those files contain deployment-specific data and are deliberately not
versioned here. Do not overwrite control sources for an in-progress rollback or reuse a
manifest whose artifact hashes differ. Normal operations check for active calls/jobs;
`--force` is an explicit emergency interruption. Start at the top video controller to preserve
cross-layer checks. There are four targets: `five`, `voice-updates`, `qwen` and `distributed`.
Use `--check` before executing. Production rollback was not performed during the final audit.

Submission validation: Python regression files run in separate processes to avoid test-module
name collisions. Run `bash tests/jarvis_regressions.sh` from a checkout; CI runs the same
entry point plus the playback-assessment and server-default policy tests. Zig 0.17.0 unit
tests need `ffmpeg` on `PATH`. The optional Qwen-ASR suite reports a skip when its
NumPy/PyTorch/Transformers environment is absent; it does not load an ASR model for these
checks. Private calibration-audio checks also report skips on a fresh checkout.
Browser regressions use mocked
model/WebSocket traffic with `PLAYWRIGHT_MODULE` set to an installed Playwright package.
`tests/voice_readiness.cjs` covers actual readiness, stale voice events, warmup failures and
legacy rollback compatibility; `tests/release_control_test.py` covers locking and bad journals.
Speech effects use `JARVIS_FFMPEG` or `ffmpeg` on `PATH`; the build machine's private ffmpeg
path is not required. Operator credentials, signing keys, model weights, APKs, media samples
and production config backups are outside this commit.
