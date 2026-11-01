#!/bin/sh
# probes from the client namespace. prints "pass" or "drop" and always exits 0.
#
#   probe.sh tcp HOST PORT          "pass" when the tcp handshake completes
#   probe.sh udp HOST PORT TOKEN    send one datagram; "pass" once upstream logged it
#   probe.sh session HOST PORT OUT  keep a tcp session sending a line every 200 ms,
#                                   the echo goes to OUT (runs until killed)
set -u
in=/run/bl/in

case $1 in
  tcp)
    if timeout 3 $in client ncat -z -w 1 "$2" "$3" 2>/dev/null; then echo pass; else echo drop; fi
    ;;
  udp)
    log=/run/bl/udp-$3.log
    echo "$4" | $in client ncat -u -w 1 --send-only "$2" "$3" 2>/dev/null
    i=0
    while [ $i -lt 10 ]; do
      if grep -q "$4" "$log" 2>/dev/null; then echo pass; exit 0; fi
      sleep 0.1
      i=$((i + 1))
    done
    echo drop
    ;;
  session)
    exec $in client sh -c \
      "while :; do date +%s.%N; sleep 0.2; done | ncat \"$2\" \"$3\" > \"$4\" 2>/dev/null"
    ;;
esac
