#!/bin/sh
# runs the mounted prod release inside the container.
#
#   gateway.sh start    start the release in the background, log to /run/bl/gateway.log
#   gateway.sh rpc EXPR evaluate EXPR on the running node
#   gateway.sh kill     kill -9 the beam, no clean shutdown
#
# the release is configured from /policies/gateway.env, written by the test.
set -eu

bl=/run/bl
rel=/opt/gateway/bin/gateway

set -a
. /policies/gateway.env
set +a
export RELEASE_TMP=$bl/release_tmp
mkdir -p "$RELEASE_TMP" "$BREAKLINE_DATA_DIR"

case $1 in
  start)
    setsid $rel start </dev/null >>$bl/gateway.log 2>&1 &
    ;;
  rpc)
    exec $rel rpc "$2"
    ;;
  kill)
    pkill -9 -f beam.smp
    while pgrep -f beam.smp >/dev/null; do sleep 0.05; done
    ;;
esac
