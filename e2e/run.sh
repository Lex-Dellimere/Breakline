#!/bin/sh
# one run of the full-stack flow against a running e2e/up.sh setup. clears the previous
# run's passkeys first (their private keys died with that browser). VIDEO=1 records it and
# writes e2e/.run/breakline-demo.mp4.
#
# env: PLAYWRIGHT_CORE (path to playwright-core), CHROME_BIN (a chromium binary)
set -eu
E=$(cd "$(dirname "$0")" && pwd)
RUN=$E/.run
: "${PLAYWRIGHT_CORE:?set PLAYWRIGHT_CORE to a playwright-core directory}"
: "${CHROME_BIN:?set CHROME_BIN to a chromium binary}"

docker exec "$(cat "$RUN/cloud.id")" sh -c \
  'RELEASE_TMP=/tmp/cloud /opt/cloud/bin/cloud rpc "Cloud.Repo.query!(\"delete from passkeys\")"' >/dev/null

# sh has no pipefail, so keep node's exit status rather than piping through tee
set +e
node "$E/flow.cjs" >"$RUN/flow.log" 2>&1
status=$?
set -e
cat "$RUN/flow.log"
[ "$status" -eq 0 ] || exit "$status"

if [ "${VIDEO:-}" = 1 ]; then
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$RUN/frames/list.txt" \
    -vf "fps=30,scale=1280:-2" -c:v libx264 -pix_fmt yuv420p -crf 22 -movflags +faststart \
    "$RUN/breakline-demo.mp4"
  echo "video: $RUN/breakline-demo.mp4"
fi
