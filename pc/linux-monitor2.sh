#!/bin/bash
# Second Sunshine on pc Linux that streams monitor 2 (Moonlight host "my-pc (Linux) Monitor 2",
# port 48089). Also stops the older setup that switched monitor 2 off during a stream.
# Run as finn on pc: bash linux-monitor2.sh <web-ui password>
set -e
PW="$1"; [ -n "$PW" ] || { echo "usage: $0 <web ui password>"; exit 1; }
C=~/.config/sunshine; M=~/.config/sunshine-m2
cp $C/sunshine.conf $C/sunshine.conf.bak-$(date +%Y%m%d-%H%M)
# monitor 1: KMS output 0, no more switching the other monitor off
sed -i '/^global_prep_cmd/d;/^output_name/d' $C/sunshine.conf
echo "output_name = 0" >> $C/sunshine.conf
systemctl --user disable --now sunshine-single-monitor.service 2>/dev/null || true
/usr/local/bin/sunshine-single-monitor stop 2>/dev/null || true

mkdir -p $M/credentials
cp $C/apps.json $M/apps.json 2>/dev/null || true
cat > $M/sunshine.conf <<CONF
sunshine_name = my-pc (Linux) Monitor 2
port = 48089
capture = kms
output_name = 1
stream_audio = disabled
file_state = $M/sunshine_state.json
credentials_file = $M/sunshine_state.json
file_apps = $M/apps.json
pkey = $M/credentials/cakey.pem
cert = $M/credentials/cacert.pem
log_path = $M/sunshine.log
CONF
SUN=$(command -v sunshine)
$SUN $M/sunshine.conf --creds finn "$PW" | tail -1

# same unit as the main Sunshine (incl. its display-wake ExecStartPre), other config
MAIN=app-dev.lizardbyte.app.Sunshine.service
U=~/.config/systemd/user/sunshine-monitor2.service
{
  echo "[Unit]"; echo "Description=Sunshine monitor 2"; echo "After=graphical-session.target"; echo "PartOf=graphical-session.target"
  echo "[Service]"
  systemctl --user cat $MAIN | grep -E '^ExecStartPre=' || true
  echo "ExecStart=$SUN $M/sunshine.conf"
  echo "Restart=on-failure"; echo "RestartSec=5"
  echo "[Install]"; echo "WantedBy=graphical-session.target"
} > $U
systemctl --user daemon-reload
systemctl --user restart $MAIN
systemctl --user enable --now sunshine-monitor2.service
sleep 8
ss -ltnp | grep -E ':(47989|48089) ' || true
tail -5 $M/sunshine.log
echo "root part (wake monitors on a monitor-2 connect): sudo nft list table inet sunshine_wake → add 48084,48089"
