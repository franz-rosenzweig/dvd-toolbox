#!/bin/zsh
# The app against stand-ins for TMDB and Jellyfin and a pretend server, never the real ones. Folders of
# short videos (made here with ffmpeg) are the discs: HandBrake reads a folder of files as a disc whose
# titles are the files. The app drives its own rip, upload and Jellyfin code; this script then checks
# the files. Pictures and the log land in WORK/out.
#
#   ./selftest.sh [WORK]          # WORK defaults to a new temporary folder
#   ./selftest.sh WORK --real     # instead: the DVD in the drive is read, its titles listed and the first
#                                 # minute of one ripped into WORK/rips (STOP_AT=seconds changes how much);
#                                 # nothing is looked up with a key and nothing is uploaded
#
# The window is on screen for a few minutes. The test copy has its own id, so the real app's settings,
# Keychain items and list of rips are never touched.
set -euo pipefail
cd "${0:A:h}"
WORK=${1:-$(mktemp -d)}; mkdir -p "$WORK"; WORK=${WORK:A}
REAL=""; [[ ${2:-} == --real ]] && REAL=1
OUT=$WORK/out; rm -rf "$OUT"; mkdir -p "$OUT"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
ID=xyz.tiresia.dvdtoolbox.selftest
fail() { echo "FAIL $*"; FAILED=1; }
ok()   { echo "PASS $*"; }
FAILED=0

DVD_OUT=$WORK/app DVD_ID=$ID DVD_NAME="DVD Toolbox Selftest" ./build.sh >/dev/null
APP="$WORK/app/DVD Toolbox Selftest.app/Contents/MacOS/DVDToolbox"
# the test copy starts clean: no settings and no rips from an earlier run
defaults delete $ID >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Application Support/$ID"
rm -rf "$WORK/rips"; mkdir -p "$WORK/rips"
defaults write $ID ripsFolder "$WORK/rips"
defaults write $ID ejectWhenDone -bool false

if [[ -n $REAL ]]; then
  ( sleep 1200; pkill -f "$APP" ) >/dev/null 2>&1 & WATCH=$!
  DVD_SELFTEST=$OUT DVD_TEST_REAL=1 DVD_TEST_RIP_DEST=$WORK/rips DVD_TEST_STOP_AT=${STOP_AT:-60} \
    "$APP" -ApplePersistenceIgnoreState YES >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || true
  kill $WATCH 2>/dev/null || true
  grep -E "^(PASS|FAIL|INFO|SELFTEST)" "$OUT/log.txt"
  [[ -f $OUT/crash.txt ]] && { echo "FAIL the app crashed:"; head -5 "$OUT/crash.txt"; exit 1; }
  for f in "$WORK"/rips/*.mkv(N); do
    echo "${f:t}:"; ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels:stream_tags=language -of compact "$f" | sed 's/^/   /'
  done
  grep -q "SELFTEST passed" "$OUT/log.txt"; exit $?
fi

# --- the discs: three episodes and a film, each title with two audio tracks
video() {  # file seconds tone
  [[ -f $1 ]] && return
  mkdir -p "${1:h}"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=720x480:rate=30000/1001" \
    -f lavfi -i "sine=frequency=$3:sample_rate=48000" -f lavfi -i "sine=frequency=$(( $3 * 2 )):sample_rate=48000" \
    -map 0 -map 1 -map 2 -c:v mpeg2video -b:v 4M -aspect 16:9 -c:a ac3 -b:a 192k -t $2 -f vob "$1"
}
video "$WORK/discs/tv/ep1.vob" 9 300; video "$WORK/discs/tv/ep2.vob" 10 400; video "$WORK/discs/tv/ep3.vob" 11 500
video "$WORK/discs/movie/feature.vob" 20 440

# --- the pretend server: the library has season 1 of Test Show with episode 1, its NFO and poster
MEDIA=$WORK/server/media
rm -rf "$WORK/server"; mkdir -p "$MEDIA/films" "$MEDIA/shows" "$MEDIA/music"
S1="$MEDIA/shows/Test Show (2020)/Season 1"; mkdir -p "$S1"
head -c 200000 /dev/urandom > "$S1/Test Show - S01E01 - Pilot.mkv"
echo original > "$MEDIA/shows/Test Show (2020)/tvshow.nfo"; echo original > "$MEDIA/shows/Test Show (2020)/poster.jpg"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 tests/standin.py $PORT "$MEDIA" "$OUT/requests.jsonl" 2>"$OUT/standin.err" & SP=$!
sleep 1
( sleep 900; pkill -f "$APP" ) >/dev/null 2>&1 & WATCH=$!
DVD_SELFTEST=$OUT \
DVD_TMDB_URL=http://127.0.0.1:$PORT/3 DVD_TMDB_IMAGES=http://127.0.0.1:$PORT/t/p DVD_TMDB_KEY=test-tmdb-key \
DVD_JELLYFIN_URL=http://127.0.0.1:$PORT/jf DVD_JELLYFIN_KEY=test-jf-key DVD_JELLYFIN_WAIT=60 \
DVD_SSH=$PWD/tests/fake-ssh DVD_SSH_TARGET=test@pretend DVD_MEDIA_PATH=$MEDIA \
DVD_TEST_TV=$WORK/discs/tv DVD_TEST_MOVIE=$WORK/discs/movie DVD_TEST_SERVER=$MEDIA \
  "$APP" -ApplePersistenceIgnoreState YES >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || true
kill $WATCH $SP 2>/dev/null || true

grep -E "^(PASS|FAIL|INFO|SELFTEST)" "$OUT/log.txt"
grep -q "SELFTEST passed" "$OUT/log.txt" || FAILED=1
[[ -f $OUT/crash.txt ]] && { fail "the app crashed:"; head -5 "$OUT/crash.txt"; }

# --- what reached the server, and what Jellyfin was told
E2="$S1/Test Show - S01E02 - Café - Two.mkv"
if [[ -f $E2 ]]; then
  streams=$(ffprobe -v error -show_entries stream=codec_type,codec_name -of csv=p=0 "$E2" | tr '\n' ' ')
  [[ $streams == "hevc,video ac3,audio ac3,audio " ]] && ok "an episode is H.265 with both AC3 tracks copied ($streams)" || fail "streams: $streams"
  cmp -s "$E2" "$WORK/rips/Shows/Test Show (2020)/Season 1/${E2:t}" && ok "the server's copy is the rip, byte for byte" || fail "the server's copy differs"
else
  fail "no episode 2 on the server"
fi
told() { grep 'Media/Updated' "$OUT/requests.jsonl" | grep '"Created"' | grep -qF "\"Path\": \"$1\""; }
told "/data/media/shows/Test Show (2020)" && ok "Jellyfin was told about the show's folder" || fail "Jellyfin was not told about the show"
told '/data/media/films/Am\u00e9lie (2001)' && ok "and about the film's" || fail "Jellyfin was not told about the film"
grep -q 'MediaBrowser Client=\\"DVD Toolbox\\".*Token=\\"test-jf-key\\"' "$OUT/requests.jsonl" && ok "with the API key in Jellyfin's Authorization header" || fail "Jellyfin's header"
[[ -z $(find "$MEDIA" -name '._*' -o -name '.DS_Store' -o -name '*.part') ]] && ok "no ._, .DS_Store or part files on the server" || fail "junk on the server: $(find "$MEDIA" -name '._*' -o -name '*.part')"
nfo="$MEDIA/films/Amélie (2001)/movie.nfo"
[[ -f $nfo ]] && grep -q '<tmdbid>194</tmdbid>' "$nfo" && ok "the film's NFO carries its TMDB id" || fail "the film's NFO"
echo "pictures: $OUT"
exit $FAILED
