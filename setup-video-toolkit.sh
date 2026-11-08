#!/usr/bin/env bash
# Video toolkit setup: Remotion, HyperFrames, FFmpeg, Whisper (whisper.cpp), yt-dlp
# Installs everything into ~/video-toolkit, then tests each tool.
# Works on macOS (needs Homebrew) and Ubuntu/Debian. On Windows, run it inside WSL.
# Run with:  bash setup-video-toolkit.sh

set -euo pipefail

KIT="$HOME/video-toolkit"
MODEL="base.en"   # Whisper model. Options: tiny.en, base.en, small.en, medium.en
mkdir -p "$KIT/out" "$KIT/models"
cd "$KIT"

say()  { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
pass() { printf "\033[1;32m  ✓ %s\033[0m\n" "$1"; RESULTS+=("✓ $1"); }
fail() { printf "\033[1;31m  ✗ %s\033[0m\n" "$1"; RESULTS+=("✗ $1"); }
RESULTS=()
OS="$(uname -s)"

# ---------------------------------------------------------------- 1. System tools
say "Installing Node, FFmpeg, yt-dlp and Whisper"
if [ "$OS" = "Darwin" ]; then
  command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
  command -v node >/dev/null || brew install node
  brew install ffmpeg yt-dlp whisper-cpp
else
  sudo apt-get update
  sudo apt-get install -y ffmpeg git cmake build-essential curl
  command -v node >/dev/null || { echo "Install Node.js 20+ first: https://nodejs.org"; exit 1; }
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  curl -fL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$HOME/.local/bin/yt-dlp"
  chmod a+rx "$HOME/.local/bin/yt-dlp"
  if [ ! -x "$KIT/whisper.cpp/build/bin/whisper-cli" ]; then
    rm -rf "$KIT/whisper.cpp"
    git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$KIT/whisper.cpp"
    cmake -S "$KIT/whisper.cpp" -B "$KIT/whisper.cpp/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$KIT/whisper.cpp/build" -j --target whisper-cli
  fi
  ln -sf "$KIT/whisper.cpp/build/bin/whisper-cli" "$HOME/.local/bin/whisper-cli"
fi

node -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)' \
  || { echo "Node 18+ is needed. You have $(node -v). Update Node and re-run."; exit 1; }

# ---------------------------------------------------------------- 2. Whisper model
say "Downloading Whisper model ($MODEL)"
[ -s "models/ggml-$MODEL.bin" ] || curl -fL \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin" \
  -o "models/ggml-$MODEL.bin"

# ---------------------------------------------------------------- 3. Remotion + HyperFrames
say "Installing Remotion and HyperFrames"
[ -f package.json ] || npm init -y >/dev/null
npm i --no-fund --no-audit remotion @remotion/cli react@18 react-dom@18 hyperframes
npx remotion browser ensure
npx hyperframes browser ensure

# Remotion test composition: 1.5s, 1080x1920, white background, fade-in text
mkdir -p remotion-test/src
cat > remotion-test/src/index.ts <<'EOF'
import {registerRoot} from 'remotion';
import {Root} from './Root';
registerRoot(Root);
EOF
cat > remotion-test/src/Root.tsx <<'EOF'
import React from 'react';
import {Composition, AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
const Test: React.FC = () => {
  const f = useCurrentFrame();
  const o = interpolate(f, [0, 20], [0, 1], {extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill style={{background: '#fff', justifyContent: 'center', alignItems: 'center'}}>
      <div style={{opacity: o, fontSize: 90, fontWeight: 800, fontFamily: 'sans-serif'}}>Remotion works</div>
    </AbsoluteFill>
  );
};
export const Root: React.FC = () => (
  <Composition id="Test" component={Test} durationInFrames={45} fps={30} width={1080} height={1920} />
);
EOF

# ---------------------------------------------------------------- 4. Tests
set +e

say "Test 1/5: Remotion"
if npx remotion render remotion-test/src/index.ts Test out/remotion-test.mp4 --log=error; then
  pass "Remotion rendered out/remotion-test.mp4"
else fail "Remotion render failed"; fi

say "Test 2/5: HyperFrames"
rm -rf hf-test
if npx hyperframes init hf-test --non-interactive --resolution=portrait; then
  node <<'JS'
const fs = require('fs'), p = 'hf-test/index.html';
let s = fs.readFileSync(p, 'utf8');
s = s.replace('--ground: #000;', '--ground: #fff;')
     .replace('--ink: #ffffff;', '--ink: #111;')
     .replaceAll(`data-duration="10"`, `data-duration="2"`)
     .replace('>Title</h1>', '>HyperFrames works</h1>')
     .replace('// Example: tl.fromTo', 'tl.fromTo')
     .replace('duration: 0.18', 'duration: 0.6');
fs.writeFileSync(p, s);
JS
  if (cd hf-test && npx hyperframes render -o ../out/hyperframes-test.mp4 -q draft --quiet); then
    pass "HyperFrames rendered out/hyperframes-test.mp4"
  else fail "HyperFrames render failed"; fi
else fail "HyperFrames init failed"; fi

say "Test 3/5: FFmpeg"
if ffmpeg -y -loglevel error -f lavfi -i testsrc2=size=1080x1920:rate=30 -t 2 \
     -c:v libx264 -pix_fmt yuv420p out/ffmpeg-test.mp4; then
  pass "FFmpeg encoded out/ffmpeg-test.mp4"
  if [ -s out/remotion-test.mp4 ] && [ -s out/hyperframes-test.mp4 ]; then
    ffmpeg -y -loglevel error -i out/remotion-test.mp4 -i out/hyperframes-test.mp4 \
      -filter_complex "[0:v]fps=30,format=yuv420p,setsar=1[a];[1:v]fps=30,format=yuv420p,setsar=1[b];[a][b]concat=n=2:v=1:a=0[v]" \
      -map "[v]" -c:v libx264 -crf 20 out/toolkit-test.mp4 \
      && pass "FFmpeg stitched both renders into out/toolkit-test.mp4"
  fi
else fail "FFmpeg failed"; fi

say "Test 4/5: Whisper"
WHISPER_BIN="$(command -v whisper-cli || command -v whisper-cpp || true)"
curl -fsL https://github.com/ggml-org/whisper.cpp/raw/master/samples/jfk.wav -o out/jfk.wav
if [ -n "$WHISPER_BIN" ] && "$WHISPER_BIN" -m "models/ggml-$MODEL.bin" -f out/jfk.wav -otxt -of out/jfk -np \
   && grep -qi "ask not" out/jfk.txt; then
  pass "Whisper transcribed the sample: $(tr -s ' \n' ' ' < out/jfk.txt | cut -c1-60)..."
else fail "Whisper transcription failed"; fi

say "Test 5/5: yt-dlp"
if yt-dlp --simulate --quiet --no-warnings "https://www.youtube.com/watch?v=jNQXAC9IVRw"; then
  pass "yt-dlp $(yt-dlp --version) can read YouTube"
else fail "yt-dlp couldn't read YouTube (try: yt-dlp -U)"; fi

# ---------------------------------------------------------------- 5. Summary
say "Summary"
printf '  %s\n' "${RESULTS[@]}"
echo
echo "Everything lives in $KIT. Test videos are in $KIT/out."
npx hyperframes doctor || true
