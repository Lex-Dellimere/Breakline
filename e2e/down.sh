#!/bin/sh
# removes every container and the network of the full-stack check. pki and secrets in
# e2e/.run are kept, so the next run reuses them
RUN=$(cd "$(dirname "$0")" && pwd)/.run
for f in gw.id cloud.id pg.id; do
  [ -s "$RUN/$f" ] && docker rm -f "$(cat "$RUN/$f")" >/dev/null 2>&1
  rm -f "$RUN/$f"
done
[ -s "$RUN/net" ] && docker network rm "$(cat "$RUN/net")" >/dev/null 2>&1
rm -f "$RUN/net" "$RUN/seed.out"
echo "e2e down"
