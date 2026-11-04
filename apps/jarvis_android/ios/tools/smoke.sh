#!/bin/zsh
# Smoke test for the native pages: launches the Debug build in each scene (the JARVIS_* debug flags), in both themes, on the
# iPhone 18 Pro Max and on the iPhone Duo's inner display, and saves a screenshot of each.
#
#   tools/smoke.sh                 build, run every scene, write tools/smoke-out/<time>/ with an index.html contact sheet
#   tools/smoke.sh --no-build      skip the build (use the app already installed)
#   tools/smoke.sh --baseline      keep this run as the baseline the next runs are compared to
#
# Every run after a baseline is compared scene by scene (ffmpeg PSNR): 'same' means pixel-identical, a number is the PSNR in dB
# (below 40 dB a person sees the change; 40 and up counts as the same), so a change that should not move a page shows up as a scene that is not 'same'.
# The status bar clock is held at 9:41 while it runs; the reactor's glow is not masked, so a scene may differ by a hair between
# two runs of the same code.
set -u
cd "${0:A:h}/.."
ROOT=$PWD
PRO=46DD78EE-C9B4-4156-B37F-04BE5CFCF59C
DUO=2B5F5AE2-12A2-4A70-8495-BF54F3D3AF93
BUNDLE=com.example.jarvis
OUT=$ROOT/tools/smoke-out
STAMP=$(date +%Y%m%d-%H%M%S)
RUN=$OUT/$STAMP
mkdir -p "$RUN"

build=1; keep=0
for a in "$@"; do
  case $a in
    --no-build) build=0 ;;
    --baseline) keep=1 ;;
  esac
done

if (( build )); then
  echo "building…"
  xcodebuild -project Runner.xcodeproj -scheme Runner -sdk iphonesimulator -configuration Debug \
    -destination 'generic/platform=iOS Simulator' build > "$RUN/build.log" 2>&1 || { tail -20 "$RUN/build.log"; exit 1; }
  APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Debug-iphonesimulator/Runner.app | head -1)
  for d in $PRO $DUO; do xcrun simctl install $d "$APP"; done
  # The first launch after an install is slow: it is done once here, so that the first scene is not shot while the app is still opening.
  for d in $PRO $DUO; do xcrun simctl launch $d $BUNDLE > /dev/null 2>&1; done; sleep 6
  for d in $PRO $DUO; do xcrun simctl terminate $d $BUNDLE > /dev/null 2>&1; done
fi

# A three second test video for the video scenes (the preview serves it for the file named `clip`).
VIDEO=$OUT/clip.mp4
[[ -f $VIDEO ]] || ffmpeg -v error -y -f lavfi -i testsrc=duration=3:size=640x360:rate=24 -pix_fmt yuv420p -c:v libx264 "$VIDEO"

# name | seconds to wait | env (space separated KEY=VALUE)
scenes=(
  "chat|3|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_MANY_CONVS=12"
  "long-reply|3|JARVIS_NATIVE_CHAT=1 JARVIS_LONG_SEED=1"
  "many-messages|4|JARVIS_NATIVE_CHAT=1 JARVIS_MANY_MSGS=60"
  "long-title|3|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_MANY_CONVS=6 JARVIS_LONG_TITLE=1"
  "works-popup|7|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_DEMO_WORK=2"
  "keyboard-up|6|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_FAKE_KEYBOARD=1"
  "settings|4|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_OPEN=settings"
  "status|5|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_OPEN=status"
  "call|5|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_OPEN=call JARVIS_CALL_DEMO=1"
  "video-chat|5|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_DEMO_VIDEO=$VIDEO"
  "video-works|7|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_DEMO_VIDEO=$VIDEO JARVIS_OPEN=works"
  "video-play|7|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_DEMO_VIDEO=$VIDEO JARVIS_OPEN=play"
  "video-broken|9|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_DEMO_VIDEO=$VIDEO JARVIS_DEMO_VIDEO_BROKEN=1 JARVIS_OPEN=play"
  "attachments|6|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_DEMO_ATTACH=4"
  "half-fold|5|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_MANY_CONVS=6 JARVIS_FOLD=1"
  "confirm-dialog|4|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_OPEN=confirm"
  "rename-dialog|4|JARVIS_NATIVE_CHAT=1 JARVIS_NATIVE_CHAT_SEED=1 JARVIS_OPEN=rename"
  "login|3|JARVIS_NATIVE_LOGIN=1"
)
themes=(dark light)
# device | udid | screenshot display (the Duo's inner display is display 3)
devices=("pro-max|$PRO|" "duo-inner|$DUO|--display=3")

shoot() {   # udid display file
  xcrun simctl io $1 screenshot ${2:+$2} "$3" > /dev/null 2>&1
}

for d in $PRO $DUO; do xcrun simctl status_bar $d override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 > /dev/null 2>&1; done
trap 'for d in $PRO $DUO; do xcrun simctl status_bar $d clear > /dev/null 2>&1; done' EXIT

for dev in $devices; do
  name=${dev%%|*}; rest=${dev#*|}; udid=${rest%%|*}; disp=${rest#*|}
  for theme in $themes; do
    for sc in $scenes; do
      sname=${sc%%|*}; rest2=${sc#*|}; wait=${rest2%%|*}; envs=${rest2#*|}
      xcrun simctl terminate $udid $BUNDLE > /dev/null 2>&1
      launch=(env)
      for kv in ${=envs} JARVIS_THEME=$theme; do launch+=("SIMCTL_CHILD_$kv"); done
      "${launch[@]}" xcrun simctl launch $udid $BUNDLE > /dev/null 2>&1 || echo "launch failed: $name $sname"
      sleep $wait
      file="$RUN/$name-$sname-$theme.png"
      shoot $udid "$disp" "$file"
      [[ -s $file ]] && echo "ok   $name $sname $theme" || echo "FAIL $name $sname $theme"
    done
  done
  xcrun simctl terminate $udid $BUNDLE > /dev/null 2>&1
done

# Compare with the baseline, when there is one.
BASE=$OUT/baseline
typeset -A verdict
if [[ -d $BASE ]]; then
  for f in $RUN/*.png; do
    b=$BASE/${f:t}
    if [[ ! -f $b ]]; then verdict[${f:t}]="new"; continue; fi
    if cmp -s "$f" "$b"; then verdict[${f:t}]="same"; continue; fi
    psnr=$(ffmpeg -v info -i "$f" -i "$b" -lavfi psnr -f null - 2>&1 | sed -n 's/.*average:\([0-9.a-z]*\).*/\1/p' | tail -1)
    # 40 dB and up is a hair (the reactor's glow): the same page
    if [[ -n $psnr && $psnr != inf ]] && (( psnr >= 40 )); then verdict[${f:t}]="same"; else verdict[${f:t}]="${psnr:-differs} dB"; fi
  done
fi

# Contact sheet.
{
  echo '<!doctype html><meta charset=utf-8><title>JARVIS smoke</title><style>body{font:13px -apple-system;background:#222;color:#ddd;margin:16px}figure{display:inline-block;margin:6px;vertical-align:top}img{height:420px;display:block;border-radius:8px}figcaption{padding:4px 0}.d{color:#f90}</style>'
  echo "<h3>$STAMP</h3>"
  for f in $RUN/*.png; do
    n=${f:t}; v=${verdict[$n]:-}
    cls=""; [[ -n $v && $v != same && $v != new ]] && cls=d
    echo "<figure><img src=\"$n\"><figcaption>${n%.png} <span class=$cls>$v</span></figcaption></figure>"
  done
} > "$RUN/index.html"

if (( keep )); then rm -rf "$BASE"; mkdir -p "$BASE"; cp "$RUN"/*.png "$BASE"/; echo "baseline kept: $BASE"; fi
echo "done: $RUN/index.html"
if (( ${#verdict} )); then
  changed=0; for k in ${(k)verdict}; do [[ ${verdict[$k]} != same ]] && { echo "  changed: $k (${verdict[$k]})"; changed=1; }; done
  (( changed )) || echo "  every scene is the same as the baseline"
fi
