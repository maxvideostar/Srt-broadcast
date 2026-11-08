#!/usr/bin/env bash
# =====================================================================
#  nTs-AIR  -  transmitator bonding 4G/5G/WiFi/Ethernet (stil AIR220)
#  Encoder HDMI -> H.264/HEVC (Intel iGPU VA / x264) -> SRT -> SRTLA bonding
#
#  Pe mini PC (transmitator):   sudo bash nts-air.sh tx
#  Pe server (receiver + panou): sudo bash nts-air.sh rx
#  Altele:  sudo bash nts-air.sh status | uninstall
#
#  Variabile optionale (rx):  WEB_PORT=8090 RX_PORT=5000 OUT="udp://127.0.0.1:5010"
#                             (doar pentru primul canal; restul din panou)
#  Variabile optionale (tx):  RX_HOST=netstreaming.eu  WEB_PORT=8080
# =====================================================================
set -e
BASE=/opt/nts-air; SRC=$BASE/src; ETC=/etc/nts-air
G='\e[32m'; Y='\e[33m'; R='\e[31m'; N='\e[0m'
say(){ echo -e "${G}==>${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
[ "$(id -u)" = 0 ] || { echo -e "${R}Ruleaza cu sudo${N}"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

fetch(){ # fetch <repo> <dir> [--recursive]
  rm -rf "$2"; git clone -q --depth 1 $3 "https://github.com/$1" "$2"
}

install_tx(){
  say "Pachete (GStreamer, VA-API Intel, build tools)"
  apt-get update -qq
  apt-get install -y -qq software-properties-common >/dev/null 2>&1 || true
  add-apt-repository -y multiverse >/dev/null 2>&1 || true
  apt-get update -qq
  apt-get install -y -qq build-essential git pkg-config python3 iproute2 v4l-utils alsa-utils curl \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-tools \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-x gstreamer1.0-alsa \
    gstreamer1.0-pulseaudio vainfo
  apt-get install -y -qq libsrt-openssl-dev 2>/dev/null || apt-get install -y -qq libsrt-dev
  apt-get install -y -qq intel-media-va-driver-non-free 2>/dev/null || apt-get install -y -qq intel-media-va-driver 2>/dev/null || true
  apt-get install -y -qq mesa-va-drivers 2>/dev/null || true   # AMD (ex. Futro S930 / GX-424CC: VCE H.264)
  apt-get install -y -qq i965-va-driver gstreamer1.0-vaapi 2>/dev/null || true

  say "Compilez belacoder (encoder cu bitrate adaptiv) si srtla_send (bonding)"
  mkdir -p $SRC $BASE/bin $ETC
  fetch BELABOX/belacoder $SRC/belacoder --recursive
  make -C $SRC/belacoder -j"$(nproc)" >/dev/null
  fetch BELABOX/srtla $SRC/srtla
  make -C $SRC/srtla -j"$(nproc)" >/dev/null
  install -m755 $SRC/belacoder/belacoder $SRC/srtla/srtla_send $BASE/bin/

  say "Panou web"
  write_app
  if [ ! -f $ETC/tx.json ]; then
    cat > $ETC/tx.json <<J
{"web_port": ${WEB_PORT:-8080}, "rx_host": "${RX_HOST:-netstreaming.eu}", "rx_port": 5000,
 "encoder": "$( [ -e /dev/dri/renderD128 ] && gst-inspect-1.0 vah264enc >/dev/null 2>&1 && echo va_h264 || echo x264 )"}
J
  fi

  say "Rutare multi-link (rp_filter loose)"
  cat > /etc/sysctl.d/90-nts-air.conf <<S
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
S
  sysctl -q --system || true

  cat > /etc/systemd/system/nts-air.service <<U
[Unit]
Description=nTs-AIR transmitter (panel + bonding)
After=network-online.target sound.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 $BASE/air.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
U
  systemctl daemon-reload; systemctl enable --now nts-air >/dev/null 2>&1; systemctl restart nts-air
  command -v ufw >/dev/null && ufw status | grep -q active && ufw allow ${WEB_PORT:-8080}/tcp >/dev/null || true
  IP=$(hostname -I | awk '{print $1}')
  echo; say "GATA. Panou: http://$IP:${WEB_PORT:-8080}  (user admin / parola admin - schimb-o din panou)"
  echo "    Encoder implicit: $(python3 -c "import json;print(json.load(open('$ETC/tx.json')).get('encoder'))")  (GPU: $(vainfo 2>/dev/null | grep -o 'Driver version: .*' | head -1))"
  echo "    Conecteaza modemuri 4G USB / telefoane cu USB tethering / WiFi / LAN - apar automat in panou."
}

install_rx(){
  WP=${WEB_PORT:-8090}
  say "Pachete build + ffmpeg"
  apt-get update -qq
  apt-get install -y -qq build-essential git cmake tclsh libssl-dev pkg-config python3 ffmpeg mpv
  apt-get install -y -qq mesa-va-drivers intel-media-va-driver vainfo 2>/dev/null || true   # decodare HW pentru iesirea HDMI
  mkdir -p $SRC $BASE/bin $ETC
  say "Compilez SRT patch-uit BELABOX (srt-live-transmit, static)"
  fetch BELABOX/srt $SRC/srt
  cmake -S $SRC/srt -B $SRC/srt/build -DCMAKE_BUILD_TYPE=Release -DENABLE_APPS=ON \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON >/dev/null
  cmake --build $SRC/srt/build -j"$(nproc)" >/dev/null
  install -m755 $SRC/srt/build/srt-live-transmit $BASE/bin/
  say "Compilez srtla_rec"
  fetch BELABOX/srtla $SRC/srtla
  make -C $SRC/srtla -j"$(nproc)" >/dev/null
  install -m755 $SRC/srtla/srtla_rec $BASE/bin/

  say "Panou receiver"
  write_rx
  # migrare de la versiunea fara panou
  if systemctl list-unit-files | grep -q '^nts-air-srt'; then
    systemctl disable --now nts-air-srt nts-air-srtla >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/nts-air-srt.service /etc/systemd/system/nts-air-srtla.service
  fi
  if [ ! -f $ETC/rx.json ]; then
    P=${RX_PORT:-5000}; OUTS="[]"; [ -n "$OUT" ] && OUTS="[\"$OUT\"]"
    if [ -f $ETC/rx.conf ]; then . $ETC/rx.conf; P=${SRTLA_PORT:-$P}; OUTS="[\"$OUTPUT\"]"; fi
    cat > $ETC/rx.json <<J
{"web_port": $WP, "web_user": "admin", "web_pass": "admin",
 "channels": [{"id": 1, "name": "cam1", "srtla_port": $P, "latency": ${LATENCY:-2000},
               "lossmaxttl": ${LOSSMAXTTL:-40}, "outputs": $OUTS, "enabled": true}]}
J
  fi
  cat > /etc/systemd/system/nts-air-rx.service <<U
[Unit]
Description=nTs-AIR receiver (panou + SRTLA)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 $BASE/rx.py
Restart=always
RestartSec=2
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
U
  systemctl daemon-reload; systemctl enable nts-air-rx >/dev/null 2>&1; systemctl restart nts-air-rx
  WP=$(python3 -c "import json;print(json.load(open('$ETC/rx.json'))['web_port'])")
  if command -v ufw >/dev/null && ufw status | grep -q active; then
    ufw allow $WP/tcp >/dev/null
    python3 -c "import json;[print(c['srtla_port']) for c in json.load(open('$ETC/rx.json'))['channels']]" | while read p; do ufw allow $p/udp >/dev/null; done
  fi
  IP=$(hostname -I | awk '{print $1}')
  echo; say "GATA. Panou receiver: http://$IP:$WP  (admin / admin - schimba parola din panou)"
  echo "    Fiecare canal = un port UDP SRTLA (implicit 5000). Deschide porturile UDP in firewall."
  echo "    Link HTTP-TS per canal: http://$IP:$WP/live/NUME.ts  (sau /NUME)"
  echo "    Iesiri extra din panou: HTTP stil Astra (http://0.0.0.0:8000/cale), multicast UDP/RTP, SRT, RTMP, HDMI"
  echo "    Pentru porturile HTTP extra (ex. 8000): ufw allow 8000/tcp"
}

status(){
  for s in nts-air nts-air-rx; do
    systemctl list-unit-files | grep -q "^$s.service" && printf "%-15s %s\n" $s "$(systemctl is-active $s)"
  done
  ip rule | grep -E "lookup 1[0-9][0-9]" || true
}

uninstall(){
  systemctl disable --now nts-air nts-air-rx 2>/dev/null || true
  rm -f /etc/systemd/system/nts-air*.service /etc/sysctl.d/90-nts-air.conf; systemctl daemon-reload
  rm -rf $BASE; say "Dezinstalat (config pastrat in $ETC)"
}

