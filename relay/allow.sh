#!/bin/bash
# Lets this Mac's paired phone use the relay (and nobody else's): stores its room in the Worker
# secret ALLOWED. Run again after "New PIN" on the phone and one Wi-Fi connection (the mirror key, and so
# the room, changes). Rooms are kept in relay/.allowed (not in git) because secrets can't be read back.
#   ./allow.sh              add the room of the phone paired with this Mac
#   ./allow.sh <mirrorKey>  add the room for that key (e.g. from the Windows PC's settings.json)
#   ./allow.sh --open       remove the list: anyone may use the relay again
set -euo pipefail
cd "$(dirname "$0")"
W="npx -y wrangler@4"
if [ "${1:-}" = "--open" ]; then $W secret delete ALLOWED --force 2>/dev/null || true; rm -f .allowed; echo "relay open to everyone"; exit 0; fi
KEY=${1:-$(defaults read de.finn.phonecast.mac mirrorKey 2>/dev/null || true)}
[ -n "$KEY" ] || { echo "no mirror key: pair the Mac with the phone first (on the same Wi-Fi)"; exit 1; }
ROOM=$(printf 'phonecast-relay:%s' "$KEY" | shasum -a 256 | cut -d' ' -f1)
touch .allowed
grep -qx "$ROOM" .allowed || echo "$ROOM" >> .allowed
tail -n 8 .allowed > .allowed.tmp && mv .allowed.tmp .allowed   # the newest 8 rooms
paste -sd, .allowed | $W secret put ALLOWED >/dev/null
echo "allowed $(wc -l < .allowed | tr -d ' ') room(s), newest ${ROOM:0:12}…"
