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

write_app(){
cat > $BASE/air.py <<'NTS_PY_EOF'
#!/usr/bin/env python3
# nTs-AIR transmitter - panel web + control belacoder/srtla_send + source routing
# Ruleaza pe Linux (Ubuntu) si Windows (MSYS2 UCRT64)
import json, os, re, signal, subprocess, threading, time, base64, glob, collections, shlex
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

WIN = os.name == "nt"
HERE = os.path.dirname(os.path.abspath(__file__))
if WIN:
    BASE = os.environ.get("NTS_AIR_BASE", HERE)
    CONF = os.environ.get("NTS_AIR_CONF", os.path.join(BASE, "tx.json"))
    RUN = os.environ.get("NTS_AIR_RUN", os.path.join(BASE, "run"))
    EXE = ".exe"
else:
    BASE = os.environ.get("NTS_AIR_BASE", "/opt/nts-air")
    CONF = os.environ.get("NTS_AIR_CONF", "/etc/nts-air/tx.json")
    RUN = os.environ.get("NTS_AIR_RUN", "/run/nts-air")
    EXE = ""
BELACODER = os.path.join(BASE, "bin", "belacoder" + EXE)
SRTLA_SEND = os.path.join(BASE, "bin", "srtla_send" + EXE)
LOCAL_SRT_PORT = 9000
RUN_GST = RUN.replace("\\", "/")   # cale sigura in pipeline GStreamer
NOWIN = 0x08000000 | 0x00000200 if WIN else 0   # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP

DEFAULT = {
    "web_port": 8080, "web_user": "admin", "web_pass": "admin",
    "rx_host": "netstreaming.eu", "rx_port": 5000, "streamid": "",
    "latency": 2000, "min_kbps": 500, "max_kbps": 7000,
    "video_src": "test", "video_dev": "" if WIN else "/dev/video0", "input_url": "",
    "width": 1920, "height": 1080, "fps": 25, "gop_sec": 2,
    "encoder": "qsv_h264" if WIN else "x264", "audio_src": "test", "audio_dev": "" if WIN else "hw:1,0",
    "audio_kbps": 128, "av_delay": 0,
    "auto_links": True, "disabled_links": [], "autostart": False,
    "dl_device": 0, "dl_mode": "auto", "dl_conn": "auto",
}

def load_conf():
    c = dict(DEFAULT)
    try:
        with open(CONF) as f: c.update(json.load(f))
    except Exception: pass
    return c

def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    tmp = CONF + ".tmp"
    with open(tmp, "w") as f: json.dump(c, f, indent=2)
    os.replace(tmp, CONF)

def sh(cmd, timeout=5):
    try: return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True,
                               timeout=timeout, creationflags=NOWIN & 0x08000000).stdout
    except Exception: return ""

# ---------------------------------------------------------------- pipeline
ENCODERS_WIN = {
    "qsv_h264":  ("Intel H.264 (Quick Sync)", "qsvh264enc name=venc_kbps rate-control=cbr bitrate={kb} gop-size={gop} b-frames=0 target-usage=4", "h264parse"),
    "qsv_h265":  ("Intel HEVC (Quick Sync)", "qsvh265enc name=venc_kbps rate-control=cbr bitrate={kb} gop-size={gop} b-frames=0 target-usage=4", "h265parse"),
    "mf_h264":   ("H.264 Media Foundation (orice GPU)", "mfh264enc name=venc_kbps rc-mode=cbr bitrate={kb} gop-size={gop} low-latency=true bframes=0", "h264parse"),
    "x264":      ("x264 (CPU)", "x264enc name=venc_kbps speed-preset=superfast tune=zerolatency bitrate={kb} key-int-max={gop} ! video/x-h264,profile=high", "h264parse"),
}
ENCODERS = {
    "x264":      ("x264 (CPU)", "x264enc name=venc_kbps speed-preset=superfast tune=zerolatency bitrate={kb} key-int-max={gop} ! video/x-h264,profile=high", "h264parse"),
    "va_h264":   ("H.264 GPU (VA-API: Intel / AMD)", "vah264enc name=venc_kbps rate-control=cbr bitrate={kb} key-int-max={gop} b-frames=0 target-usage=4", "h264parse"),
    "va_h265":   ("HEVC GPU (VA-API, nu pe AMD vechi)", "vah265enc name=venc_kbps rate-control=cbr bitrate={kb} key-int-max={gop} b-frames=0 target-usage=4", "h265parse"),
    "vaapi_h264":("Intel H.264 (VAAPI vechi)", "vaapih264enc name=venc_kbps rate-control=cbr bitrate={kb} keyframe-period={gop}", "h264parse"),
    "vaapi_h265":("Intel HEVC (VAAPI vechi)", "vaapih265enc name=venc_kbps rate-control=cbr bitrate={kb} keyframe-period={gop}", "h265parse"),
}
if WIN: ENCODERS = ENCODERS_WIN

def gst_q(v):
    """valoare intre ghilimele pentru gst_parse_launch (escape backslash/ghilimele)"""
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'

def win_video_src(dev):
    return "mfvideosrc " + (f"device-path={gst_q(dev)}" if dev else "device-index=0")

def norm_url(u):
    u = str(u or "").strip().replace('"', "").replace(" ", "%20")
    if u.startswith("udp://@"): u = "udp://" + u[7:]          # stil ffmpeg/VLC
    if u.startswith("rtp://@"): u = "rtp://" + u[7:]
    return u

def build_pipeline(c):
    w, h, fps = int(c["width"]), int(c["height"]), int(c["fps"])
    gop = max(1, int(c["gop_sec"]) * fps)
    vs = c["video_src"]; dev = c["video_dev"]
    if WIN and vs in ("mjpeg", "yuy2", "auto"):
        src = win_video_src(dev)
        if vs == "mjpeg":
            v = f"{src} ! image/jpeg,width={w},height={h},framerate={fps}/1 ! jpegparse ! jpegdec"
        elif vs == "yuy2":
            v = f"{src} ! video/x-raw,width={w},height={h},framerate={fps}/1"
        else:
            v = f"{src} ! decodebin ! videoconvert ! videoscale ! videorate ! video/x-raw,width={w},height={h},framerate={fps}/1"
    elif vs == "mjpeg":
        v = f"v4l2src device={dev} do-timestamp=true ! image/jpeg,width={w},height={h},framerate={fps}/1 ! jpegparse ! jpegdec"
    elif vs == "yuy2":
        v = f"v4l2src device={dev} do-timestamp=true ! video/x-raw,format=YUY2,width={w},height={h},framerate={fps}/1"
    elif vs == "decklink":
        dl = f"device-number={int(c.get('dl_device', 0))}"
        v = (f"decklinkvideosrc {dl} mode={c.get('dl_mode', 'auto')} connection={c.get('dl_conn', 'auto')} ! "
             f"queue ! videoconvert ! deinterlace method=linear ! videoconvert ! videoscale ! videorate ! "
             f"video/x-raw,width={w},height={h},framerate={fps}/1")
    elif vs == "url":
        v = (f'uridecodebin uri="{norm_url(c.get("input_url"))}" name=src '
             f"src. ! queue max-size-time=3000000000 ! videoconvert ! videoscale ! videorate ! "
             f"video/x-raw,width={w},height={h},framerate={fps}/1")
    elif vs == "auto":
        v = f"v4l2src device={dev} do-timestamp=true ! decodebin ! videoconvert ! videoscale ! videorate ! video/x-raw,width={w},height={h},framerate={fps}/1"
    else:
        v = (f"videotestsrc is-live=true pattern=smpte ! video/x-raw,width={w},height={h},framerate={fps}/1 ! "
             f"timeoverlay halignment=right valignment=bottom font-desc=\"Sans 28\" ! "
             f"textoverlay text=\"nTs-AIR TEST\" halignment=left valignment=top font-desc=\"Sans 28\"")
    enc, parse = ENCODERS.get(c["encoder"], ENCODERS["x264"])[1:]
    enc = enc.format(kb=int(c["max_kbps"]), gop=gop)
    p = (f"{v} ! identity name=v_delay signal-handoffs=TRUE ! queue ! videoconvert ! video/x-raw,format=NV12 ! tee name=t "
         f"t. ! queue max-size-buffers=2 leaky=downstream ! videorate max-rate=2 ! videoscale ! videoconvert ! "
         f"video/x-raw,width=384,height=216 ! jpegenc quality=60 ! multifilesink location={RUN_GST}/preview.jpg "
         f"t. ! queue ! {enc} ! {parse} config-interval=-1 ! "
         f"queue max-size-time=10000000000 max-size-buffers=1000 max-size-bytes=41943040 ! mux. ")
    a = c["audio_src"]
    if a != "none":
        if a == "decklink":
            asrc = f"decklinkaudiosrc device-number={int(c.get('dl_device', 0))} channels=2"
        elif a == "url" and vs == "url":
            asrc = "src. ! queue max-size-time=3000000000"
        elif a == "wasapi" or (WIN and a in ("alsa", "pulse")):
            d = c.get("audio_dev", "")
            asrc = "wasapi2src low-latency=true" + (f" device={gst_q(d)}" if d else "")
        elif a == "alsa":
            asrc = f"alsasrc device={c['audio_dev']} do-timestamp=true"
        elif a == "pulse":
            asrc = "pulsesrc do-timestamp=true"
        else:
            asrc = "audiotestsrc is-live=true wave=sine freq=1000 volume=0.05"
        p += (f"{asrc} ! identity name=a_delay signal-handoffs=TRUE ! audioconvert ! audioresample ! "
              f"audio/x-raw,rate=48000,channels=2 ! avenc_aac bitrate={int(c['audio_kbps'])*1000} ! aacparse ! "
              f"queue max-size-time=10000000000 max-size-buffers=1000 ! mux. ")
    p += "mpegtsmux name=mux alignment=7 ! appsink name=appsink"
    return p

# ---------------------------------------------------------------- links / routing
CELL_DRV = ("cdc_ether", "rndis_host", "qmi_wwan", "cdc_mbim", "huawei_cdc_ncm", "cdc_ncm", "option", "ipheth")
SKIP = re.compile(r"^(lo|docker|veth|br-|virbr|tun|tap|wg|zt|tailscale|vmnet|vbox)")

def link_kind(ifn):
    if os.path.isdir(f"/sys/class/net/{ifn}/wireless") or ifn.startswith("wl"): return "wifi"
    if ifn.startswith(("ppp", "wwan", "usb")): return "cell"
    try:
        drv = os.path.basename(os.readlink(f"/sys/class/net/{ifn}/device/driver"))
        if drv in CELL_DRV: return "cell"
    except Exception: pass
    return "eth"

def detect_links():
    out = []
    try:
        addrs = json.loads(sh(["ip", "-j", "-4", "addr", "show"]) or "[]")
        routes = json.loads(sh(["ip", "-j", "-4", "route", "show", "table", "main"]) or "[]")
    except Exception:
        return out
    for a in addrs:
        ifn = a.get("ifname", "")
        if SKIP.match(ifn) or "UP" not in a.get("flags", []): continue
        for ai in a.get("addr_info", []):
            if ai.get("family") != "inet": continue
            ip, plen = ai["local"], ai.get("prefixlen", 32)
            gw = None
            for r in routes:
                if r.get("dev") == ifn and r.get("dst") == "default" and r.get("gateway"):
                    gw = r["gateway"]; break
            if not gw:
                for r in routes:
                    if r.get("dev") == ifn and r.get("gateway"): gw = r["gateway"]; break
            out.append({"if": ifn, "ip": ip, "plen": plen, "gw": gw, "kind": link_kind(ifn),
                        "idx": a.get("ifindex", 0)})
            break
    return out

# --- Windows: psutil + Get-NetAdapter (fara rutare: Windows trimite pe interfata IP-ului sursa)
WIN_SKIP = re.compile(r"(loopback|vethernet|hyper-v|virtualbox|vmware|tap-|wireguard|tailscale|zerotier|bluetooth|wintun|npcap|teredo|isatap)", re.I)
WIN_CELL = re.compile(r"(remote ndis|rndis|mobile|wwan|lte|5g|4g|huawei|zte|quectel|sierra|fibocom|telit|hilink|modem|android|iphone|apple mobile)", re.I)
_win_ad = {"t": 0, "map": {}}

def win_adapters():
    if time.time() - _win_ad["t"] > 20:
        _win_ad["t"] = time.time()
        out = sh(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                  "Get-NetAdapter | Select-Object Name,InterfaceDescription,PhysicalMediaType,ifIndex | ConvertTo-Json -Compress"], 15)
        try:
            j = json.loads(out or "[]")
            if isinstance(j, dict): j = [j]
            _win_ad["map"] = {a["Name"]: a for a in j}
        except Exception: pass
    return _win_ad["map"]

def detect_links_win():
    import psutil, socket as so
    out = []; ad = win_adapters()
    st = psutil.net_if_stats()
    for name, addrs in psutil.net_if_addrs().items():
        if not st.get(name) or not st[name].isup: continue
        a = ad.get(name, {})
        desc = (a.get("InterfaceDescription") or "") + " " + name
        if WIN_SKIP.search(desc): continue
        for ai in addrs:
            if ai.family != so.AF_INET or ai.address.startswith(("127.", "169.254.")): continue
            pm = str(a.get("PhysicalMediaType") or "")
            kind = "wifi" if ("802.11" in pm or re.search(r"wi-?fi|wireless|wlan", desc, re.I)) else \
                   "cell" if ("Wireless WAN" in pm or WIN_CELL.search(desc)) else "eth"
            out.append({"if": name, "ip": ai.address, "plen": 0, "gw": None, "kind": kind,
                        "idx": a.get("ifIndex", 0), "desc": a.get("InterfaceDescription", "")})
            break
    return out

if WIN:
    detect_links = detect_links_win

class Router:
    def __init__(self): self.applied = {}
    def apply(self, links):
        if WIN: return
        want = {}
        for l in links:
            t = 100 + int(l["idx"])
            want[t] = (l["if"], l["ip"], l["plen"], l["gw"])
        for t in list(self.applied):
            if t not in want or self.applied[t] != want[t]:
                self.flush(t); del self.applied[t]
        for t, (ifn, ip, plen, gw) in want.items():
            if t in self.applied: continue
            self.flush(t)
            net = sh(["ip", "-4", "route", "show", "dev", ifn, "scope", "link", "proto", "kernel"]).split()
            if net: sh(["ip", "route", "add", net[0], "dev", ifn, "src", ip, "table", str(t)])
            if gw: sh(["ip", "route", "add", "default", "via", gw, "dev", ifn, "table", str(t)])
            else:  sh(["ip", "route", "add", "default", "dev", ifn, "table", str(t)])
            sh(["ip", "rule", "add", "from", ip, "table", str(t), "priority", str(1000 + t)])
            self.applied[t] = want[t]
    def flush(self, t):
        for _ in range(10):
            r = subprocess.run(["ip", "rule", "del", "table", str(t)], capture_output=True)
            if r.returncode: break
        sh(["ip", "route", "flush", "table", str(t)])
    def clear(self):
        if WIN: return
        for t in list(self.applied): self.flush(t)
        self.applied = {}

def read_netdev():
    d = {}
    if WIN:
        try:
            import psutil
            for n, v in psutil.net_io_counters(pernic=True).items(): d[n] = (v.bytes_recv, v.bytes_sent)
        except Exception: pass
        return d
    try:
        for line in open("/proc/net/dev").read().splitlines()[2:]:
            n, v = line.split(":", 1); v = v.split()
            d[n.strip()] = (int(v[0]), int(v[8]))
    except Exception: pass
    return d

# ---------------------------------------------------------------- engine
class Engine:
    def __init__(self):
        self.c = load_conf()
        self.lock = threading.RLock()
        self.live = False; self.t0 = None
        self.enc = None; self.bond = None
        self.log = collections.deque(maxlen=300)
        self.router = Router()
        self.links = []; self.rates = {}; self.prev = None; self.prev_t = None
        self.srt_state = "IDLE"; self.restarts = 0
        self.ipfile = RUN + "/srtla_ips"; self.brfile = RUN + "/bitrate"; self.plfile = RUN + "/pipeline"
        os.makedirs(RUN, exist_ok=True)
        threading.Thread(target=self.loop, daemon=True).start()

    def L(self, s):
        self.log.append(time.strftime("%H:%M:%S ") + s.rstrip())

    def active_links(self):
        dis = set(self.c.get("disabled_links", []))
        return [l for l in self.links if l["if"] not in dis] if self.c.get("auto_links", True) else \
               [l for l in self.links if l["if"] in set(self.c.get("enabled_links", []))]

    def write_ips(self):
        ips = "\n".join(l["ip"] for l in self.active_links()) + "\n"
        old = open(self.ipfile).read() if os.path.exists(self.ipfile) else None
        if ips != old:
            with open(self.ipfile, "w") as f: f.write(ips)
            if self.bond and self.bond.poll() is None:
                if not WIN: self.bond.send_signal(signal.SIGHUP)   # pe Windows srtla_send citeste singur fisierul
                self.L("Legaturi actualizate: " + ips.strip().replace("\n", ", "))

    def write_bitrate(self):
        with open(self.brfile, "w") as f:
            f.write(f"{int(self.c['min_kbps'])*1000}\n{int(self.c['max_kbps'])*1000}\n")

    def reader(self, p, tag):
        for line in iter(p.stdout.readline, ""):
            if not line: break
            if "SRT connected" in line: self.srt_state = "LIVE"
            if "Failed to establish" in line or "timed out" in line or "failed" in line.lower(): self.srt_state = "RECONNECT"
            self.L(f"[{tag}] {line}")

    def spawn(self, cmd, tag):
        self.L(f"[{tag}] start: " + " ".join(shlex.quote(x) for x in cmd))
        kw = {"creationflags": NOWIN} if WIN else {"start_new_session": True}
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                             encoding="utf-8", errors="replace", **kw)
        threading.Thread(target=self.reader, args=(p, tag), daemon=True).start()
        return p

    def start_bond(self):
        c = self.c
        self.bond = self.spawn([SRTLA_SEND, str(LOCAL_SRT_PORT), str(c["rx_host"]), str(c["rx_port"]), self.ipfile], "srtla")

    def start_enc(self):
        c = self.c
        with open(self.plfile, "w") as f: f.write(build_pipeline(c))
        self.write_bitrate()
        cmd = [BELACODER, self.plfile, "127.0.0.1", str(LOCAL_SRT_PORT), "-l", str(int(c["latency"])), "-b", self.brfile]
        if int(c.get("av_delay", 0)): cmd += ["-d", str(int(c["av_delay"]))]
        if c.get("streamid"): cmd += ["-s", str(c["streamid"])]
        self.srt_state = "CONNECTING"
        self.enc = self.spawn(cmd, "enc")

    def start(self):
        with self.lock:
            if self.live: return
            self.live = True; self.t0 = time.time(); self.restarts = 0
            self.write_ips(); self.start_bond(); time.sleep(0.5); self.start_enc()

    def kill(self, p):
        if p and p.poll() is None and WIN:
            try: p.terminate(); p.wait(3)
            except Exception: pass
            return
        if p and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM); p.wait(3)
            except Exception:
                try: os.killpg(p.pid, signal.SIGKILL)
                except Exception: pass

    def stop(self):
        with self.lock:
            self.live = False; self.t0 = None
            self.kill(self.enc); self.kill(self.bond); self.enc = self.bond = None
            self.srt_state = "IDLE"; self.L("STOP")

    def set_bitrate(self, kbps):
        with self.lock:
            self.c["max_kbps"] = max(int(self.c["min_kbps"]) + 100, min(50000, int(kbps)))
            save_conf(self.c); self.write_bitrate()
            if self.enc and self.enc.poll() is None and not WIN: self.enc.send_signal(signal.SIGHUP)

    def loop(self):
        n = 0
        while True:
            try:
                self.links = detect_links()
                self.router.apply(self.links)
                now = time.time(); cur = read_netdev()
                if self.prev:
                    dt = max(0.1, now - self.prev_t)
                    self.rates = {k: {"tx": (v[1] - self.prev.get(k, v)[1]) * 8 / dt / 1e6,
                                      "rx": (v[0] - self.prev.get(k, v)[0]) * 8 / dt / 1e6} for k, v in cur.items()}
                self.prev, self.prev_t = cur, now
                with self.lock:
                    if self.live:
                        self.write_ips()
                        if self.bond and self.bond.poll() is not None:
                            self.L("srtla_send oprit, repornesc"); self.start_bond()
                        if self.enc and self.enc.poll() is not None:
                            self.restarts += 1; self.srt_state = "RECONNECT"
                            self.L("encoder oprit, repornesc in 2s"); time.sleep(2)
                            if self.live: self.start_enc()
            except Exception as e:
                self.L("eroare loop: %s" % e)
            n += 1; time.sleep(1)

    def status(self):
        act = {l["if"] for l in self.active_links()}
        links = []
        total = 0.0
        for l in self.links:
            r = self.rates.get(l["if"], {"tx": 0, "rx": 0})
            on = l["if"] in act
            if on and self.live: total += r["tx"]
            links.append(dict(l, tx=round(r["tx"], 2), rx=round(r["rx"], 2), on=on))
        return {"live": self.live, "state": self.srt_state if self.live else "IDLE",
                "uptime": int(time.time() - self.t0) if self.t0 else 0,
                "total_mbps": round(total, 2), "max_kbps": self.c["max_kbps"], "restarts": self.restarts,
                "links": links, "log": list(self.log)[-60:],
                "has_preview": os.path.exists(RUN + "/preview.jpg") and self.live}

def gst_unesc(x):
    return re.sub(r"\\(.)", r"\1", x)

_devcache = {"t": 0, "v": None}
def devices_win():
    if _devcache["v"] and time.time() - _devcache["t"] < 60: return _devcache["v"]
    out = sh(["gst-device-monitor-1.0", "Video/Source", "Audio/Source"], 15)
    v, a = [], []
    for blk in out.split("Device found:")[1:]:
        name = re.search(r"name\s*:\s*(.+)", blk); cls = re.search(r"class\s*:\s*(\S+)", blk)
        name = name.group(1).strip() if name else "?"; cls = cls.group(1) if cls else ""
        mv = re.search(r'mfvideosrc device-path="((?:[^"\\]|\\.)*)"', blk) or re.search(r"mfvideosrc device-path=(\S+)", blk)
        ma = re.search(r'wasapi2src device="((?:[^"\\]|\\.)*)"', blk) or re.search(r"wasapi2src device=(\S+)", blk)
        if cls.startswith("Video") and mv:
            v.append({"dev": gst_unesc(mv.group(1)), "name": name})
        elif cls.startswith("Audio") and ma and "loopback" not in blk.lower():
            a.append({"dev": gst_unesc(ma.group(1)), "name": name})
    r = {"video": v, "audio": a, "gpu": True, "platform": "win",
         "encoders": {k: x[0] for k, x in ENCODERS.items()}}
    _devcache.update(t=time.time(), v=r)
    return r

def devices():
    if WIN: return devices_win()
    v = []
    for d in sorted(glob.glob("/dev/video*")):
        n = os.path.basename(d)
        try: name = open(f"/sys/class/video4linux/{n}/name").read().strip()
        except Exception: name = n
        v.append({"dev": d, "name": name})
    a = []
    for m in re.finditer(r"card (\d+): ([^,]+).*?device (\d+): ([^\n]+)", sh("arecord -l")):
        a.append({"dev": f"hw:{m.group(1)},{m.group(3)}", "name": f"{m.group(2).strip()} / {m.group(4).strip()}"})
    gpu = os.path.exists("/dev/dri/renderD128")
    return {"video": v, "audio": a, "gpu": gpu, "platform": "linux",
            "decklink": sorted(glob.glob("/dev/blackmagic/io*") + glob.glob("/dev/blackmagic/dv*")),
            "encoders": {k: v[0] for k, v in ENCODERS.items()}}

E = None
HTML = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "air.html")).read() \
    if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "air.html")) else "<h1>air.html lipsa</h1>"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def auth(self):
        tok = base64.b64encode(f"{E.c['web_user']}:{E.c['web_pass']}".encode()).decode()
        if self.headers.get("Authorization") == "Basic " + tok: return True
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="nTs-AIR"'); self.end_headers()
        return False
    def out(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)): body = json.dumps(body)
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        try: return json.loads(self.rfile.read(n) or b"{}")
        except Exception: return {}
    def do_GET(self):
        if not self.auth(): return
        p = self.path.split("?")[0]
        if p == "/": return self.out(200, HTML, "text/html; charset=utf-8")
        if p == "/api/status": return self.out(200, E.status())
        if p == "/api/config":
            c = dict(E.c); c.pop("web_pass", None); return self.out(200, c)
        if p == "/api/devices": return self.out(200, devices())
        if p == "/api/pipeline": return self.out(200, build_pipeline(E.c), "text/plain")
        if p == "/preview.jpg":
            try:
                data = open(RUN + "/preview.jpg", "rb").read()
                if data[-2:] == b"\xff\xd9": return self.out(200, data, "image/jpeg")
            except Exception: pass
            return self.out(404, b"", "image/jpeg")
        self.out(404, {"err": "not found"})
    def do_POST(self):
        if not self.auth(): return
        p = self.path; b = self.body()
        if p == "/api/start": E.start(); return self.out(200, {"ok": 1})
        if p == "/api/stop": E.stop(); return self.out(200, {"ok": 1})
        if p == "/api/bitrate":
            if "delta" in b: E.set_bitrate(int(E.c["max_kbps"]) + int(b["delta"]))
            else: E.set_bitrate(int(b.get("kbps", E.c["max_kbps"])))
            return self.out(200, {"max_kbps": E.c["max_kbps"]})
        if p == "/api/link":
            dis = set(E.c.get("disabled_links", []))
            (dis.discard if b.get("on") else dis.add)(b.get("if", ""))
            E.c["disabled_links"] = sorted(dis); save_conf(E.c)
            if E.live: E.write_ips()
            return self.out(200, {"ok": 1})
        if p == "/api/config":
            with E.lock:
                for k, v in b.items():
                    if k in DEFAULT and not (k == "web_pass" and not v):
                        E.c[k] = type(DEFAULT[k])(v) if not isinstance(DEFAULT[k], list) else v
                save_conf(E.c)
                was = E.live
            if was: E.stop(); E.start()
            return self.out(200, {"ok": 1, "restarted": was})
        self.out(404, {"err": "not found"})

def main():
    global E
    E = Engine()
    def bye(*a):
        E.stop(); E.router.clear(); os._exit(0)
    signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
    if E.c.get("autostart"): E.start()
    srv = ThreadingHTTPServer(("0.0.0.0", int(E.c["web_port"])), H)
    print("nTs-AIR panel pe port", E.c["web_port"], flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
NTS_PY_EOF
cat > $BASE/air.html <<'NTS_HTML_EOF'
<!DOCTYPE html>
<html lang="ro"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>nTs-AIR Transmitter</title>
<style>
:root{--bg:#0e1013;--card:#171a1f;--line:#262b33;--tx:#e6e9ee;--mut:#8a93a0;--acc:#2bd46b;--red:#ff3b3b;--blue:#3aa0ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.4 system-ui,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1200px;margin:auto;padding:16px;display:grid;grid-template-columns:minmax(320px,460px) 1fr;gap:16px}
@media(max-width:860px){.wrap{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px}
h2{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);margin:0 0 10px}
/* ---- device ---- */
.dev{background:linear-gradient(160deg,#2a2d31,#15171a);border-radius:22px;padding:18px 18px 14px;box-shadow:0 10px 30px #0008,inset 0 1px 0 #ffffff14;position:relative}
.dev .vents{height:10px;margin:0 30px 14px;background:repeating-linear-gradient(90deg,#0a0b0c 0 10px,transparent 10px 15px);border-radius:3px;opacity:.8}
.face{display:flex;gap:12px;align-items:stretch}
.brand{writing-mode:vertical-rl;transform:rotate(180deg);color:#9aa1a9;font-weight:700;letter-spacing:.15em;font-size:13px;border-left:2px solid #c0392b;padding-left:4px}
.lcd{flex:1;aspect-ratio:16/10.5;background:#000;border-radius:6px;border:3px solid #050505;position:relative;overflow:hidden;box-shadow:0 0 0 1px #333}
.lcd img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:.85}
.lcd .nopv{position:absolute;inset:0;background:linear-gradient(135deg,#0b2a4a,#071322)}
.lcd .meter{position:absolute;left:0;right:0;top:0;height:6px;display:flex;gap:2px;padding:1px 4px}
.lcd .meter i{flex:1;background:#2bd46b33}.lcd .meter i.on{background:#2bd46b}.lcd .meter i.on.y{background:#f1c40f}.lcd .meter i.on.r{background:var(--red)}
.lcd .br{position:absolute;left:50%;top:30%;transform:translate(-50%,-50%);background:#3a6fa8e6;border:2px solid #cfe3ff;padding:2px 12px;border-radius:4px;font-weight:800;font-size:clamp(22px,6vw,34px);white-space:nowrap;text-shadow:0 1px 2px #0008}
.lcd .br small{font-size:.6em}
.lcd .tm{position:absolute;left:50%;top:56%;transform:translateX(-50%);background:#000a;padding:1px 10px 1px 24px;border-radius:10px;font:700 15px ui-monospace,monospace}
.lcd .tm:before{content:"";position:absolute;left:8px;top:50%;width:10px;height:10px;margin-top:-5px;border-radius:50%;background:#777}
.lcd.live .tm:before{background:var(--red);animation:bl 1s infinite}.lcd.conn .tm:before{background:#f39c12;animation:bl .4s infinite}
@keyframes bl{50%{opacity:.2}}
.lcd .st{position:absolute;left:0;right:0;bottom:0;height:22%;background:#1f3550f0;display:flex;align-items:center;gap:8px;padding:0 8px}
.lcd .st .ic{display:flex;align-items:flex-end;gap:3px;font-size:11px;color:#cfe3ff}
.lcd .st .ic svg{width:18px;height:18px;fill:#cfe3ff;opacity:.35}.lcd .st .ic.on svg{opacity:1}
.lcd .st .bar{flex:1;height:8px;background:#0006;border-radius:4px;overflow:hidden}.lcd .st .bar i{display:block;height:100%;background:var(--acc);width:0;transition:width .5s}
.lcd .state{position:absolute;right:6px;top:10px;font:700 10px ui-monospace;background:#000a;padding:1px 5px;border-radius:3px}
.side{display:flex;flex-direction:column;gap:8px;justify-content:center;padding:6px 2px}
.led{width:12px;height:12px;border-radius:50%;background:#1c3324;box-shadow:inset 0 0 2px #000}
.led.g{background:var(--acc);box-shadow:0 0 8px var(--acc)}.led.w{background:#fff;box-shadow:0 0 8px #fff}.led.r{background:var(--red);box-shadow:0 0 8px var(--red)}
.ctrl{display:flex;justify-content:center;gap:16px;margin-top:14px;align-items:center}
.btn{width:46px;height:46px;border-radius:12px;background:linear-gradient(#2b2e33,#111);border:1px solid #000;color:#ccd;font-size:18px;cursor:pointer;box-shadow:0 3px 0 #000}
.knob{width:70px;height:70px;border-radius:50%;cursor:pointer;border:2px solid #000;
 background:repeating-conic-gradient(#25282c 0 6deg,#111 6deg 12deg);box-shadow:0 4px 0 #000,inset 0 0 0 10px #1a1c1f;color:#fff;font-weight:800;font-size:12px}
.knob.live{box-shadow:0 4px 0 #000,inset 0 0 0 10px #1a1c1f,0 0 16px var(--red)}
.btn:active,.knob:active{transform:translateY(2px);box-shadow:0 1px 0 #000}
.hint{text-align:center;color:var(--mut);font-size:12px;margin-top:8px}
/* ---- right ---- */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:10px}
label{display:block;font-size:12px;color:var(--mut)}
input,select{width:100%;margin-top:3px;background:#0e1115;border:1px solid var(--line);color:var(--tx);padding:7px 8px;border-radius:7px}
button.p{background:var(--blue);border:0;color:#fff;padding:9px 16px;border-radius:8px;font-weight:600;cursor:pointer}
table{width:100%;border-collapse:collapse}td,th{padding:6px 4px;border-bottom:1px solid var(--line);text-align:left;font-size:13px}th{color:var(--mut);font-weight:500}
.lb{height:6px;background:#0006;border-radius:3px;overflow:hidden;min-width:60px}.lb i{display:block;height:100%;background:var(--acc)}
.tag{font-size:11px;padding:1px 6px;border-radius:9px;background:#263040}
pre{background:#090b0d;border-radius:8px;padding:10px;max-height:260px;overflow:auto;font-size:11px;margin:0;white-space:pre-wrap}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.stack{display:flex;flex-direction:column;gap:16px}
.sw{width:auto}
</style></head><body>
<div class="wrap">
 <div class="stack">
  <div class="dev">
   <div class="vents"></div>
   <div class="face">
    <div class="brand">nTs-AIR</div>
    <div class="lcd" id="lcd">
     <div class="nopv" id="nopv"></div><img id="pv" alt="" style="display:none">
     <div class="meter" id="meter"></div>
     <div class="state" id="state">IDLE</div>
     <div class="br" id="br">0.00 <small>Mbps</small></div>
     <div class="tm" id="tm">00:00:00</div>
     <div class="st"><div id="icons" class="row" style="gap:8px"></div><div class="bar"><i id="fill"></i></div></div>
    </div>
    <div class="side"><div class="led" id="l1"></div><div class="led" id="l2"></div><div class="led" id="l3"></div></div>
   </div>
   <div class="ctrl">
    <button class="btn" onclick="br(-500)" title="-0.5 Mbps">◀</button>
    <button class="knob" id="knob" onclick="toggle()">LIVE</button>
    <button class="btn" onclick="br(500)" title="+0.5 Mbps">▶</button>
   </div>
   <div class="hint">Buton central = START/STOP · ◀ ▶ = bitrate maxim <b id="maxb"></b></div>
  </div>
  <div class="card"><h2>Legături (bonding)</h2>
   <table><thead><tr><th></th><th>Interfață</th><th>IP</th><th>TX</th><th></th></tr></thead><tbody id="links"></tbody></table>
  </div>
 </div>
 <div class="stack">
  <div class="card"><h2>Destinație (receiver)</h2><div class="grid">
   <label>Server srtla_rec<input id="rx_host"></label>
   <label>Port UDP<input id="rx_port" type="number"></label>
   <label>Stream ID<input id="streamid"></label>
   <label>Latență SRT (ms)<input id="latency" type="number"></label>
  </div></div>
  <div class="card"><h2>Encoder</h2><div class="grid">
   <label>Sursă video<select id="video_src">
     <option value="test">Test pattern</option><option value="mjpeg">Captură HDMI USB (MJPEG)</option>
     <option value="yuy2">Captură HDMI (YUY2 / CamLink)</option><option value="auto">Captură (auto-detect)</option>
     <option value="url">Link rețea (RTSP/SRT/RTMP/UDP/HLS)</option>
     <option value="decklink" class="lnx">Blackmagic DeckLink (SDI/HDMI)</option></select></label>
   <label class="dlbox">DeckLink placa<select id="dl_device"><option value="0">0</option><option value="1">1</option><option value="2">2</option><option value="3">3</option></select></label>
   <label class="dlbox">DeckLink mod<select id="dl_mode"><option>auto</option><option>1080i50</option><option>1080p25</option><option>1080p50</option><option>720p50</option><option>pal</option><option>1080i5994</option><option>1080p30</option></select></label>
   <label class="dlbox">DeckLink intrare<select id="dl_conn"><option>auto</option><option>sdi</option><option>hdmi</option></select></label>
   <label id="urlbox" style="grid-column:1/-1">Link sursă<input id="input_url" placeholder="rtsp://user:pass@192.168.1.64:554/Streaming/Channels/101  ·  srt://ip:9000  ·  rtmp://server/live/cheie  ·  udp://@239.1.1.1:1234  ·  http://.../index.m3u8"></label>
   <label>Dispozitiv video<select id="video_dev"></select></label>
   <label>Encoder<select id="encoder"></select></label>
   <label>Rezoluție<select id="res"><option>1920x1080</option><option>1280x720</option><option>3840x2160</option><option>720x576</option></select></label>
   <label>FPS<select id="fps"><option>25</option><option>30</option><option>50</option><option>60</option></select></label>
   <label>GOP (sec)<input id="gop_sec" type="number"></label>
   <label>Bitrate minim (kbps)<input id="min_kbps" type="number"></label>
   <label>Bitrate maxim (kbps)<input id="max_kbps" type="number"></label>
   <label>Sursă audio<select id="audio_src"><option value="url">Din link</option><option value="decklink" class="lnx">DeckLink (embedded)</option><option value="wasapi" class="win">WASAPI (placă captură / microfon)</option><option value="alsa" class="lnx">ALSA (placă captură)</option><option value="pulse" class="lnx">PulseAudio</option><option value="test">Ton test</option><option value="none">Fără audio</option></select></label>
   <label>Dispozitiv audio<select id="audio_dev"></select></label>
   <label>Audio AAC (kbps)<input id="audio_kbps" type="number"></label>
   <label>Decalaj A/V (ms)<input id="av_delay" type="number"></label>
  </div>
  <div class="row" style="margin-top:12px">
   <label class="row" style="color:var(--tx)"><input type="checkbox" id="autostart" class="sw"> Pornire automată la boot</label>
   <label>Parolă panel nouă<input id="web_pass" type="password" placeholder="(neschimbată)"></label>
   <button class="p" onclick="save()">Salvează</button><span id="msg" style="color:var(--acc)"></span>
  </div></div>
  <div class="card"><h2>Jurnal</h2><pre id="log"></pre></div>
 </div>
</div>
<script>
const $=id=>document.getElementById(id);
const ICON={eth:'<svg viewBox="0 0 24 24"><path d="M4 9h16v9h-3v-3h-2v3h-2v-3h-2v3H9v-3H7v3H4z"/></svg>',
 wifi:'<svg viewBox="0 0 24 24"><path d="M12 18a2 2 0 110 4 2 2 0 010-4zm-4.2-2.8a6 6 0 018.4 0l-1.4 1.4a4 4 0 00-5.6 0zM4.9 12.4a10 10 0 0114.2 0l-1.4 1.4a8 8 0 00-11.4 0zM2 9.5a14 14 0 0120 0L20.6 11A12 12 0 003.4 11z"/></svg>',
 cell:'<svg viewBox="0 0 24 24"><path d="M3 20h3v-4H3zm5 0h3v-8H8zm5 0h3V8h-3zm5 0h3V3h-3z"/></svg>'};
for(let i=0;i<24;i++){const e=document.createElement('i');e.className=i>19?'r':i>15?'y':'';$('meter').appendChild(e)}
let S={},C={};
async function api(p,b){const r=await fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:{});return r.headers.get('content-type').includes('json')?r.json():r.text()}
const fmt=s=>[s/3600|0,(s/60|0)%60,s%60].map(x=>String(x).padStart(2,'0')).join(':');
function toggle(){api(S.live?'/api/stop':'/api/start',{}).then(tick)}
function br(d){api('/api/bitrate',{delta:d}).then(r=>{$('max_kbps').value=r.max_kbps;tick()})}
function link(i,on){api('/api/link',{if:i,on}).then(tick)}
async function tick(){
 try{S=await api('/api/status')}catch(e){return}
 const lcd=$('lcd');lcd.className='lcd'+(S.live?(S.state=='LIVE'?' live':' conn'):'');
 $('br').innerHTML=S.total_mbps.toFixed(2)+' <small>Mbps</small>';$('tm').textContent=fmt(S.uptime);
 $('state').textContent=S.state;$('maxb').textContent=(S.max_kbps/1000).toFixed(1)+' Mbps';
 $('knob').textContent=S.live?'STOP':'LIVE';$('knob').classList.toggle('live',S.live);
 $('fill').style.width=Math.min(100,S.total_mbps/(S.max_kbps/1000)*100)+'%';
 const lv=Math.round(Math.min(1,S.total_mbps/(S.max_kbps/1000))*24);[...$('meter').children].forEach((e,i)=>e.classList.toggle('on',S.live&&i<lv));
 const kinds={};S.links.forEach(l=>{if(l.on)kinds[l.kind]=1});
 $('icons').innerHTML=['eth','wifi','cell'].map(k=>`<span class="ic ${kinds[k]?'on':''}">${ICON[k]}</span>`).join('');
 $('l1').className='led g';$('l2').className='led '+(S.links.some(l=>l.on)?'g':'');$('l3').className='led '+(S.live?(S.state=='LIVE'?'r':'w'):'');
 if(S.has_preview){$('pv').src='/preview.jpg?'+Date.now();$('pv').style.display='';$('nopv').style.display='none'}else{$('pv').style.display='none';$('nopv').style.display=''}
 const mx=Math.max(1,...S.links.map(l=>l.tx));
 $('links').innerHTML=S.links.map(l=>`<tr><td><input type="checkbox" class="sw" ${l.on?'checked':''} onchange="link('${l.if}',this.checked)"></td>
  <td>${l.if} <span class="tag">${{eth:'Ethernet',wifi:'WiFi',cell:'4G/5G'}[l.kind]}</span></td><td>${l.ip}</td>
  <td>${l.tx.toFixed(2)} Mbps</td><td><div class="lb"><i style="width:${l.tx/mx*100}%"></i></div></td></tr>`).join('')||'<tr><td colspan=5>Nicio interfață cu IP</td></tr>';
 const lg=$('log'),atB=lg.scrollTop+lg.clientHeight>=lg.scrollHeight-5;lg.textContent=S.log.join('\n');if(atB)lg.scrollTop=lg.scrollHeight;
}
async function load(){
 const [c,d]=await Promise.all([api('/api/config'),api('/api/devices')]);C=c;
 const W=d.platform=='win',E=s=>String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;');
 document.querySelectorAll(W?'.lnx':'.win').forEach(o=>o.remove());
 const vl=W?[{dev:'',name:'Primul dispozitiv'}].concat(d.video):(d.video.length?d.video:[{dev:'/dev/video0',name:'(niciunul detectat)'}]);
 const al=W?[{dev:'',name:'Implicit Windows'}].concat(d.audio):(d.audio.length?d.audio:[{dev:'hw:1,0',name:'(niciunul detectat)'}]);
 $('video_dev').innerHTML=vl.map(v=>`<option value="${E(v.dev)}">${W?E(v.name):E(v.dev)+' – '+E(v.name)}</option>`).join('');
 $('audio_dev').innerHTML=al.map(v=>`<option value="${E(v.dev)}">${W?E(v.name):E(v.dev)+' – '+E(v.name)}</option>`).join('');
 $('encoder').innerHTML=Object.entries(d.encoders).map(([k,v])=>`<option value="${k}">${v}</option>`).join('');
 ['rx_host','rx_port','streamid','latency','video_src','video_dev','input_url','dl_device','dl_mode','dl_conn','encoder','fps','gop_sec','min_kbps','max_kbps','audio_src','audio_dev','audio_kbps','av_delay'].forEach(k=>{if($(k))$(k).value=c[k]});
 $('res').value=c.width+'x'+c.height;$('autostart').checked=!!c.autostart;
}
function srcUI(user){const u=$('video_src').value=='url';$('urlbox').style.display=u?'':'none';
 const dk=$('video_src').value=='decklink';document.querySelectorAll('.dlbox').forEach(e=>e.style.display=dk?'':'none');
 if(dk&&user&&['test','alsa','url'].includes($('audio_src').value))$('audio_src').value='decklink';
 const a=$('audio_src');[...a.options].find(o=>o.value=='url').disabled=!u;if(u&&user&&a.value=='test')a.value='url';if(!u&&a.value=='url')a.value='test'}
async function save(){
 const b={};['rx_host','streamid','video_src','video_dev','input_url','encoder','audio_src','audio_dev','web_pass','dl_mode','dl_conn'].forEach(k=>b[k]=$(k).value);b.dl_device=+$('dl_device').value;
 ['rx_port','latency','fps','gop_sec','min_kbps','max_kbps','audio_kbps','av_delay'].forEach(k=>b[k]=+$(k).value);
 const [w,h]=$('res').value.split('x');b.width=+w;b.height=+h;b.autostart=$('autostart').checked;
 const r=await api('/api/config',b);$('msg').textContent=r.restarted?'Salvat – transmisia a repornit':'Salvat';setTimeout(()=>$('msg').textContent='',3000);$('web_pass').value='';
}
$('video_src').onchange=()=>srcUI(true);
load().then(()=>srcUI(false));tick();setInterval(tick,1000);
</script></body></html>
NTS_HTML_EOF
chmod 755 $BASE/air.py
}

write_rx(){
cat > $BASE/rx.py <<'NTS_RXPY_EOF'
#!/usr/bin/env python3
# nTs-AIR Receiver - panou StreamHub-like pentru transmitatoare bonded (SRTLA)
import json, os, re, signal, socket, struct, subprocess, threading, time, base64, collections, shlex, queue, glob
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote

BASE = os.environ.get("NTS_AIR_BASE", "/opt/nts-air")
CONF = os.environ.get("NTS_AIR_RXCONF", "/etc/nts-air/rx.json")
RUN = os.environ.get("NTS_AIR_RUN", "/run/nts-air-rx")
SRTLA_REC = BASE + "/bin/srtla_rec"
SLT = BASE + "/bin/srt-live-transmit"
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")

DEFAULT = {"web_port": 8090, "web_user": "admin", "web_pass": "admin", "channels": []}
CH_DEFAULT = {"name": "cam1", "srtla_port": 5000, "latency": 2000, "lossmaxttl": 40,
              "outputs": [], "enabled": True}
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,40}$")

def load_conf():
    c = json.loads(json.dumps(DEFAULT))
    try:
        with open(CONF) as f: c.update(json.load(f))
    except Exception: pass
    for i, ch in enumerate(c["channels"]):
        for k, v in CH_DEFAULT.items(): ch.setdefault(k, v)
        ch.setdefault("id", i + 1)
    return c

def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF + ".tmp", "w") as f: json.dump(c, f, indent=2)
    os.replace(CONF + ".tmp", CONF)

def now(): return time.time()

# ------------------------------------------------------------- link sniffer
class Sniffer:
    """Numara bytes per (ip_sursa, port_sursa) pentru porturile SRTLA (AF_PACKET + BPF)."""
    def __init__(self):
        self.ports = set(); self.lock = threading.Lock()
        self.cnt = collections.defaultdict(int)  # (dport, src, sport) -> bytes
        self.seen = {}
        self.sock = None; self.ok = False
        try:
            self.sock = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(0x0800))
            self.ok = True
            threading.Thread(target=self.run, daemon=True).start()
        except Exception as e:
            print("sniffer indisponibil:", e, flush=True)

    def set_ports(self, ports):
        ports = set(ports)
        if ports == self.ports or not self.ok: return
        self.ports = ports
        lo, hi = (min(ports), max(ports)) if ports else (1, 0)
        # BPF pe header IP (SOCK_DGRAM): UDP, nefragmentat, dport in [lo,hi]
        prog = [
            (0x30, 0, 0, 9),            # ldb [9]
            (0x15, 0, 7, 17),           # jeq udp
            (0x28, 0, 0, 6),            # ldh [6]
            (0x45, 5, 0, 0x1fff),       # jset frag -> drop
            (0xb1, 0, 0, 0),            # ldx 4*([0]&0xf)
            (0x48, 0, 0, 2),            # ldh [x+2]  dport
            (0x35, 0, 2, lo),           # jge lo
            (0x25, 1, 0, hi),           # jgt hi -> drop
            (0x06, 0, 0, 64),           # ret 64
            (0x06, 0, 0, 0),            # ret 0
        ]
        import ctypes
        raw = b"".join(struct.pack("HBBI", *i) for i in prog)
        buf = ctypes.create_string_buffer(raw)
        fprog = struct.pack("HL", len(prog), ctypes.addressof(buf))
        self._buf = buf
        try: self.sock.setsockopt(socket.SOL_SOCKET, 26, fprog)  # SO_ATTACH_FILTER
        except Exception as e: print("BPF:", e, flush=True)

    def run(self):
        while True:
            try:
                data, addr = self.sock.recvfrom(128)
            except Exception:
                time.sleep(0.1); continue
            if addr[2] == 4 or len(data) < 28: continue   # PACKET_OUTGOING
            ihl = (data[0] & 15) * 4
            if data[9] != 17: continue
            tot = struct.unpack("!H", data[2:4])[0]
            sport, dport = struct.unpack("!HH", data[ihl:ihl + 4])
            if dport not in self.ports: continue
            src = socket.inet_ntoa(data[12:16])
            k = (dport, src, sport)
            with self.lock:
                self.cnt[k] += tot; self.seen[k] = now()

    def take(self):
        with self.lock:
            c = dict(self.cnt); self.cnt.clear()
            t = now()
            for k in [k for k, v in self.seen.items() if t - v > 30]: del self.seen[k]
            return c, dict(self.seen)

RDNS = {}
def rdns(ip):
    if ip in RDNS: return RDNS[ip]
    RDNS[ip] = ""
    def w():
        try: RDNS[ip] = socket.gethostbyaddr(ip)[0]
        except Exception: RDNS[ip] = "-"
    threading.Thread(target=w, daemon=True).start()
    return ""

OPERATORS = [("orange", "Orange"), ("vodafone", "Vodafone"), ("rcs-rds", "Digi"), ("digi", "Digi"),
             ("telekom", "Telekom"), ("cosmote", "Telekom"), ("romtelecom", "Telekom"), ("upc", "Vodafone")]
def operator(host):
    h = (host or "").lower()
    for k, v in OPERATORS:
        if k in h: return v
    return ""

# ------------------------------------------------------------- HDMI (mpv pe DRM/KMS, fara desktop)
MPV = os.environ.get("MPV", "mpv")

def hdmi_connectors():
    out = []
    for st in sorted(glob.glob("/sys/class/drm/card*-*/status")):
        name = os.path.basename(os.path.dirname(st))          # card1-HDMI-A-1
        card, _, conn = name.partition("-")
        try: status = open(st).read().strip()
        except Exception: status = "?"
        if conn.startswith(("Writeback", "Virtual")): continue
        out.append({"card": card, "connector": conn, "status": status})
    return out

def hdmi_cmd(u, src):
    """hdmi://?connector=HDMI-A-1&card=card1&audio=alsa/hdmi:CARD=PCH,DEV=0&hwdec=auto-safe"""
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    conn = q.get("connector") or (u.hostname if u.hostname and u.hostname != "auto" else "")
    card = q.get("card", "")
    if not conn:
        for c in hdmi_connectors():
            if c["status"] == "connected": conn, card = c["connector"], card or c["card"]; break
    cmd = [MPV, "--no-terminal", "--msg-level=all=warn", "--fs", "--no-osc", "--no-input-default-bindings",
           "--profile=low-latency", "--cache=no", "--hwdec=" + q.get("hwdec", "auto-safe"),
           "--vo=" + q.get("vo", "gpu")]
    if q.get("vo", "gpu") == "gpu":
        cmd.append("--gpu-context=drm")
        if card: cmd.append("--drm-device=/dev/dri/" + card)
        if conn: cmd.append("--drm-connector=" + conn)
        if q.get("mode"): cmd.append("--drm-mode=" + q["mode"])
    if q.get("audio"): cmd.append("--audio-device=" + q["audio"])
    if q.get("ao"): cmd.append("--ao=" + q["ao"])
    cmd.append(src)
    return cmd

# ------------------------------------------------------------- DeckLink (Blackmagic) SDI/HDMI out
GST_LAUNCH = os.environ.get("GST_LAUNCH", "gst-launch-1.0")
DL_MODES = {  # mod -> (latime, inaltime, fps_num, fps_den, intercalat)
    "1080i50": (1920, 1080, 25, 1, True), "1080p25": (1920, 1080, 25, 1, False), "1080p50": (1920, 1080, 50, 1, False),
    "1080i5994": (1920, 1080, 30000, 1001, True), "1080p2997": (1920, 1080, 30000, 1001, False),
    "1080p30": (1920, 1080, 30, 1, False), "720p50": (1280, 720, 50, 1, False), "720p5994": (1280, 720, 60000, 1001, False),
    "pal": (720, 576, 25, 1, True), "ntsc": (720, 486, 30000, 1001, True),
}

def decklink_devices():
    return sorted(glob.glob("/dev/blackmagic/io*") + glob.glob("/dev/blackmagic/dv*"))

def decklink_cmd(u, src):
    """decklink://?device=0&mode=1080i50&audio=1"""
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    dev_s = str(q.get("device") or u.hostname or "0")
    dev = int(dev_s) if dev_s.isdigit() else 0
    mode = q.get("mode", "1080i50")
    w, h, fn, fd, inter = DL_MODES.get(mode, DL_MODES["1080i50"])
    fake = q.get("sink") == "fake"
    vsink = "fakesink sync=true" if fake else f"decklinkvideosink device-number={dev} mode={mode} sync=true"
    asink = "fakesink sync=true" if fake else f"decklinkaudiosink device-number={dev} sync=true"
    if inter:   # cadre progresive la 2x fps -> interlace (fiecare cadru = un camp)
        vchain = (f"videorate ! video/x-raw,framerate={fn*2}/{fd} ! interlace field-pattern=1:1 top-field-first=true ! "
                  f"videoconvert ! video/x-raw,format=UYVY,width={w},height={h}")
    else:
        vchain = f"videorate ! video/x-raw,framerate={fn}/{fd} ! videoconvert ! video/x-raw,format=UYVY,width={w},height={h}"
    pipe = (f"uridecodebin uri={src} name=d "
            f"d. ! queue max-size-time=2000000000 ! deinterlace ! videoconvert ! videoscale add-borders=true ! "
            f"video/x-raw,width={w},height={h},pixel-aspect-ratio=1/1 ! {vchain} ! {vsink} ")
    if q.get("audio", "1") != "0":
        pipe += (f"d. ! queue max-size-time=2000000000 ! audioconvert ! audioresample ! "
                 f"audio/x-raw,format=S32LE,rate=48000,channels=2 ! {asink}")
    return [GST_LAUNCH, "-q"] + shlex.split(pipe)

# ------------------------------------------------------------- iesiri HTTP stil Astra
def stream_to_client(h, ch, internal=False):
    """trimite MPEG-TS catre clientul HTTP h (BaseHTTPRequestHandler)"""
    q = queue.Queue(maxsize=2000)
    ip = h.headers.get("X-Real-IP") or h.client_address[0]
    ch.cid += 1; cid = ch.cid
    ch.clients[cid] = {"ip": ip, "t": now(), "ua": h.headers.get("User-Agent", ""), "q": q,
                       "drop": 0, "internal": internal}
    h.close_connection = True
    try:
        h.send_response(200); h.send_header("Content-Type", "video/mp2t")
        h.send_header("Cache-Control", "no-cache"); h.send_header("Connection", "close")
        h.send_header("Access-Control-Allow-Origin", "*")
        h.end_headers()
        buf = bytearray()
        while True:
            try: d = q.get(timeout=10)
            except queue.Empty: break
            if d is None: break
            buf += d
            if len(buf) >= 1316 * 5 or q.empty():
                h.wfile.write(buf); buf.clear()
    except Exception: pass
    finally:
        ch.clients.pop(cid, None)

class HttpOuts:
    """servere HTTP pe porturi separate: http://0.0.0.0:8000/cale -> canal (ca output-ul http din Astra)"""
    def __init__(self):
        self.lock = threading.Lock(); self.servers = {}; self.routes = {}
    def add(self, host, port, path, ch):
        key = (host, int(port))
        with self.lock:
            self.routes.setdefault(key, {})[path] = ch
            if key in self.servers: return True
            mgr = self
            class HH(BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"
                def log_message(self, *a): pass
                def do_GET(self):
                    pth = unquote(self.path.split("?")[0])
                    with mgr.lock: c = mgr.routes.get(key, {}).get(pth)
                    if c is None or not c.running:
                        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
                    stream_to_client(self, c)
            try:
                srv = ThreadingHTTPServer((host, int(port)), HH); srv.daemon_threads = True
            except OSError as e:
                ch.L(f"HTTP {host}:{port} indisponibil: {e}")
                return False
            self.servers[key] = srv
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            ch.L(f"HTTP output pornit pe {host}:{port}")
            return True
    def remove(self, k3, ch):
        host, port, path = k3; key = (host, int(port))
        with self.lock:
            r = self.routes.get(key, {})
            if r.get(path) is ch: del r[path]
            if not r and key in self.servers:
                srv = self.servers.pop(key); self.routes.pop(key, None)
                threading.Thread(target=srv.shutdown, daemon=True).start()
                try: srv.server_close()
                except Exception: pass

# ------------------------------------------------------------- channel
class Proc:
    def __init__(self, tag, cmd, on_line=None, log=None):
        self.tag, self.cmd, self.on_line, self.log = tag, cmd, on_line, log
        self.p = None; self.backoff = 1; self.next = 0
    def start(self):
        self.log(f"[{self.tag}] start: " + " ".join(shlex.quote(x) for x in self.cmd))
        try:
            self.p = subprocess.Popen(self.cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                      bufsize=1, start_new_session=True)
        except Exception as e:
            self.log(f"[{self.tag}] eroare: {e}"); self.p = None; return
        threading.Thread(target=self.read, args=(self.p,), daemon=True).start()
    def read(self, p):
        for line in iter(p.stdout.readline, ""):
            if self.on_line and self.on_line(line): continue
            self.log(f"[{self.tag}] {line}")
    def alive(self): return self.p is not None and self.p.poll() is None
    def check(self):
        if self.alive(): self.backoff = 1; return
        if now() < self.next: return
        if self.p is not None: self.log(f"[{self.tag}] oprit (cod {self.p.poll()}), repornesc")
        self.next = now() + self.backoff; self.backoff = min(30, self.backoff * 2)
        self.start()
    def stop(self):
        if self.alive():
            try: os.killpg(self.p.pid, signal.SIGTERM); self.p.wait(3)
            except Exception:
                try: os.killpg(self.p.pid, signal.SIGKILL)
                except Exception: pass
        self.p = None

class Channel:
    def __init__(self, cfg, hub):
        self.cfg = cfg; self.hub = hub; self.id = int(cfg["id"])
        self.log = collections.deque(maxlen=200)
        self.lock = threading.Lock()
        self.srt_up = False; self.last_stats = 0; self.connected_at = None
        self.stats = {}; self.loss = collections.deque(maxlen=60)
        self.bytes = 0; self.rate = 0.0; self.hist = collections.deque(maxlen=120)
        self.clients = {}  # id -> dict
        self.cid = 0
        self.info = {}; self.thumb_t = 0; self.thumb_busy = False
        self.links = {}; self.last_data = 0
        self.procs = []; self.udp_out = []; self.helpers = []; self.http_out = []
        self.running = False; self.rx_sock = None

    # porturi interne unice per canal
    @property
    def p_srt(self): return 40000 + self.id * 10
    @property
    def p_udp(self): return 40001 + self.id * 10
    def p_helper(self, k): return 40002 + self.id * 10 + k

    def L(self, s): self.log.append(time.strftime("%H:%M:%S ") + s.rstrip())

    def on_slt(self, line):
        s = line.strip()
        if s.startswith("{") and '"recv"' in s:
            try:
                j = json.loads(s); r = j.get("recv", {}); l = j.get("link", {})
                self.stats = {"rtt": round(l.get("rtt", 0), 1), "bw": round(l.get("bandwidth", 0), 1),
                              "srt_mbps": round(r.get("mbitRate", 0), 2)}
                self.loss.append((now(), r.get("packetsLost", 0), r.get("packetsDropped", 0),
                                  r.get("packetsRetransmitted", 0), r.get("packets", 0)))
                self.last_stats = now()
            except Exception: pass
            return True
        if "Accepted SRT" in s or "SRT source connected" in s:
            self.srt_up = True
        if "source disconnected" in s:
            self.srt_up = False
        return False

    def start(self):
        c = self.cfg; self.running = True
        lat, ttl = int(c["latency"]), int(c["lossmaxttl"])
        slt = Proc("srt", [SLT, "-a:yes", "-s:500", "-pf:json",
                           f"srt://127.0.0.1:{self.p_srt}?mode=listener&lossmaxttl={ttl}&latency={lat}",
                           f"udp://127.0.0.1:{self.p_udp}"], self.on_slt, self.L)
        rec = Proc("srtla", [SRTLA_REC, str(int(c["srtla_port"])), "127.0.0.1", str(self.p_srt)], None, self.L)
        self.procs = [slt, rec]
        self.udp_out = []; self.helpers = []; self.http_out = []
        for k, url in enumerate(c.get("outputs", [])):
            url = url.strip()
            if not url: continue
            u = urlparse(url)
            if u.scheme in ("udp", "rtp"):
                q = parse_qs(u.query)
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, int(q.get("ttl", ["4"])[0]))
                    if "localaddr" in q:
                        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(q["localaddr"][0]))
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
                except Exception: pass
                self.udp_out.append({"url": url, "sock": s, "addr": (u.hostname, u.port or 1234), "err": 0,
                                     "rtp": u.scheme == "rtp", "seq": 0, "ssrc": int.from_bytes(os.urandom(4), "big")})
            elif u.scheme == "http":
                path = u.path if u.path not in ("", "/") else "/" + c["name"]
                ok = self.hub.httpouts.add(u.hostname or "0.0.0.0", u.port or 8000, path, self)
                self.http_out.append({"url": url, "key": (u.hostname or "0.0.0.0", u.port or 8000, path), "ok": ok})
            elif u.scheme in ("srt", "rtmp", "rtmps", "hdmi", "decklink"):
                hp = self.p_helper(k + 0) if k < 8 else None
                if hp is None: continue
                if u.scheme == "srt":
                    cmd = [SLT, "-a:yes", f"udp://127.0.0.1:{hp}", url]
                elif u.scheme == "hdmi":
                    cmd = hdmi_cmd(u, f"udp://127.0.0.1:{hp}")
                elif u.scheme == "decklink":
                    cmd = decklink_cmd(u, f"udp://127.0.0.1:{hp}")
                else:
                    cmd = [FFMPEG, "-hide_banner", "-loglevel", "warning", "-fflags", "+genpts",
                           "-f", "mpegts", "-i", f"udp://127.0.0.1:{hp}?fifo_size=1000000&overrun_nonfatal=1",
                           "-c", "copy", "-f", "flv", url]
                hs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self.helpers.append({"url": url, "proc": Proc("out%d" % k, cmd, None, self.L),
                                     "sock": hs, "addr": ("127.0.0.1", hp)})
        for p in self.procs: p.start()
        for h in self.helpers: h["proc"].start()
        self.rx_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        for _ in range(20):
            try: self.rx_sock.bind(("127.0.0.1", self.p_udp)); break
            except OSError: time.sleep(0.25)
        self.rx_sock.settimeout(0.5)
        threading.Thread(target=self.relay, args=(self.rx_sock,), daemon=True).start()

    def relay(self, sock):
        while self.running:
            try: data = sock.recv(65536)
            except socket.timeout: continue
            except Exception: break
            self.bytes += len(data); self.last_data = now()
            for o in self.udp_out:
                try:
                    if o["rtp"]:
                        o["seq"] = (o["seq"] + 1) & 0xFFFF
                        hdr = struct.pack("!BBHII", 0x80, 33, o["seq"], int(now() * 90000) & 0xFFFFFFFF, o["ssrc"])
                        o["sock"].sendto(hdr + data, o["addr"])
                    else:
                        o["sock"].sendto(data, o["addr"])
                except Exception: o["err"] += 1
            for h in self.helpers:
                try: h["sock"].sendto(data, h["addr"])
                except Exception: pass
            for cl in list(self.clients.values()):
                try: cl["q"].put_nowait(data)
                except queue.Full: cl["drop"] += 1
        try: sock.close()
        except Exception: pass

    def stop(self):
        self.running = False
        try: self.rx_sock.close()
        except Exception: pass
        for p in self.procs: p.stop()
        for h in self.helpers: h["proc"].stop(); h["sock"].close()
        for o in self.udp_out: o["sock"].close()
        for o in self.http_out: self.hub.httpouts.remove(o["key"], self)
        self.http_out = []
        for cl in list(self.clients.values()):
            try: cl["q"].put_nowait(None)
            except Exception: pass
        self.procs = []; self.helpers = []; self.udp_out = []
        self.srt_up = False; self.connected_at = None

    def onair(self): return self.running and now() - self.last_data < 3

    def tick(self, dt, link_bytes, seen):
        if not self.running: return
        for p in self.procs: p.check()
        for h in self.helpers: h["proc"].check()
        b, self.bytes = self.bytes, 0
        self.rate = b * 8 / dt / 1e6
        self.hist.append(round(self.rate, 2))
        if self.onair():
            if not self.connected_at: self.connected_at = now(); self.L("ON AIR")
        elif self.connected_at:
            self.connected_at = None; self.L("semnal pierdut"); self.info = {}
        port = int(self.cfg["srtla_port"])
        links = {}
        for (dp, ip, sp), n in link_bytes.items():
            if dp == port: links[(ip, sp)] = n
        t = now()
        out = []
        for (dp, ip, sp), ts in seen.items():
            if dp != port or t - ts > 5: continue
            host = rdns(ip) if not RDNS.get(ip) else RDNS[ip]
            out.append({"ip": ip, "port": sp, "mbps": round(links.get((ip, sp), 0) * 8 / dt / 1e6, 2),
                        "host": host if host != "-" else "", "op": operator(host)})
        out.sort(key=lambda x: -x["mbps"])
        self.links = out
        if self.onair() and not self.thumb_busy and t - self.thumb_t > 10:
            self.thumb_t = t; threading.Thread(target=self.thumb, daemon=True).start()

    def thumb(self):
        self.thumb_busy = True
        try:
            os.makedirs(RUN, exist_ok=True)
            out = f"{RUN}/thumb_{self.id}.jpg"
            src = f"http://127.0.0.1:{self.hub.conf['web_port']}/live/{self.cfg['name']}.ts?thumb=1"
            r = subprocess.run([FFMPEG, "-hide_banner", "-y", "-analyzeduration", "3000000", "-i", src,
                                "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "6", out + ".tmp.jpg"],
                               capture_output=True, text=True, timeout=15)
            if os.path.exists(out + ".tmp.jpg"): os.replace(out + ".tmp.jpg", out)
            info = {}
            for line in r.stderr.splitlines():
                if "Video:" in line and "video" not in info:
                    cod = re.search(r"Video: (\w+)", line); res = re.search(r" (\d{3,5})x(\d{3,5})", line)
                    fps = re.search(r"([\d.]+) fps", line)
                    info["video"] = (cod.group(1).upper() if cod else "?") + (f" {res.group(1)}x{res.group(2)}" if res else "") + (f" {fps.group(1)}fps" if fps else "")
                if "Audio:" in line and "audio" not in info:
                    cod = re.search(r"Audio: (\w+)", line); hz = re.search(r"(\d+) Hz", line)
                    info["audio"] = (cod.group(1).upper() if cod else "?") + (f" {int(hz.group(1))//1000}kHz" if hz else "")
            if info: self.info = info
        except Exception as e:
            self.L(f"thumb: {e}")
        finally:
            self.thumb_busy = False

    def status(self):
        c = self.cfg; t = now()
        lost = drop = retr = pk = 0
        for (ts, l, d, rt, p) in self.loss:
            if t - ts < 10: lost += l; drop += d; retr += rt; pk += p
        st = "OFF" if not self.running else ("ON AIR" if self.onair() else "ASTEAPTA")
        return {"id": self.id, "name": c["name"], "srtla_port": c["srtla_port"], "latency": c["latency"],
                "lossmaxttl": c["lossmaxttl"], "outputs": c.get("outputs", []), "enabled": c.get("enabled", True),
                "state": st, "mbps": round(self.rate, 2), "hist": list(self.hist),
                "uptime": int(t - self.connected_at) if self.connected_at else 0,
                "rtt": self.stats.get("rtt", 0) if t - self.last_stats < 5 else 0,
                "lost10": lost, "drop10": drop, "retr10": retr, "pk10": pk,
                "links": self.links, "info": self.info,
                "thumb": os.path.exists(f"{RUN}/thumb_{self.id}.jpg") and self.onair(),
                "clients": [{"ip": v["ip"], "since": int(t - v["t"]), "ua": v["ua"][:60], "drop": v["drop"]}
                            for v in list(self.clients.values()) if not v.get("internal")],
                "out_status": [{"url": o["url"], "ok": True} for o in self.udp_out] +
                              [{"url": o["url"], "ok": o["ok"], "http": True,
                                "port": o["key"][1], "path": o["key"][2]} for o in self.http_out] +
                              [{"url": h["url"], "ok": h["proc"].alive()} for h in self.helpers],
                "log": list(self.log)[-40:]}

# ------------------------------------------------------------- hub
class Hub:
    def __init__(self):
        self.conf = load_conf(); self.lock = threading.RLock()
        self.chans = {}; self.sniff = Sniffer(); self.t0 = now(); self.httpouts = HttpOuts()
        for c in self.conf["channels"]:
            self.add(c, save=False)
        threading.Thread(target=self.loop, daemon=True).start()

    def ports(self): self.sniff.set_ports([int(c.cfg["srtla_port"]) for c in self.chans.values() if c.running])

    def add(self, cfg, save=True):
        ch = Channel(cfg, self)
        self.chans[ch.id] = ch
        if cfg.get("enabled", True): ch.start()
        if save: self.save()
        self.ports(); return ch

    def save(self):
        self.conf["channels"] = [c.cfg for c in sorted(self.chans.values(), key=lambda x: x.id)]
        save_conf(self.conf)

    def validate(self, b, cur_id=None):
        name = str(b.get("name", "")).strip()
        if not NAME_RE.match(name): return "Nume invalid (litere, cifre, _ . -)"
        try: port = int(b.get("srtla_port"))
        except Exception: return "Port invalid"
        if not 1024 <= port <= 39999: return "Portul SRTLA trebuie intre 1024 si 39999"
        for c in self.chans.values():
            if c.id == cur_id: continue
            if c.cfg["name"] == name: return "Exista deja un canal cu acest nume"
            if int(c.cfg["srtla_port"]) == port: return "Portul e deja folosit de " + c.cfg["name"]
        if port == int(self.conf["web_port"]): return "Port ocupat de panou"
        outs = b.get("outputs", [])
        if isinstance(outs, str): outs = outs.splitlines()
        for o in outs:
            o = o.strip()
            if not o: continue
            u = urlparse(o)
            if u.scheme not in ("udp", "rtp", "srt", "rtmp", "rtmps", "http", "hdmi", "decklink"):
                return "Ieșire necunoscută: " + o
            if u.scheme == "http":
                hp = u.port or 8000
                if hp == int(self.conf["web_port"]):
                    return f"Portul {hp} e al panoului (acolo /live/NUME.ts e deja activ) - alege alt port"
                path = u.path if u.path not in ("", "/") else "/" + name
                for c in self.chans.values():
                    if c.id == cur_id: continue
                    for o2 in c.cfg.get("outputs", []):
                        u2 = urlparse(o2.strip())
                        if u2.scheme == "http" and (u2.port or 8000) == hp:
                            p2 = u2.path if u2.path not in ("", "/") else "/" + c.cfg["name"]
                            if p2 == path: return f"Calea {path} pe portul {hp} e deja folosită de {c.cfg['name']}"
        return None

    def norm(self, b):
        outs = b.get("outputs", [])
        if isinstance(outs, str): outs = outs.splitlines()
        return {"name": str(b["name"]).strip(), "srtla_port": int(b["srtla_port"]),
                "latency": max(80, min(10000, int(b.get("latency", 2000)))),
                "lossmaxttl": max(0, min(500, int(b.get("lossmaxttl", 40)))),
                "outputs": [o.strip() for o in outs if o.strip()][:8],
                "enabled": bool(b.get("enabled", True))}

    def create(self, b):
        with self.lock:
            e = self.validate(b)
            if e: return e
            cfg = self.norm(b); cfg["id"] = max([0] + list(self.chans)) + 1
            if cfg["id"] > 2400: return "Prea multe canale"
            self.add(cfg); return None

    def update(self, cid, b):
        with self.lock:
            ch = self.chans.get(cid)
            if not ch: return "Canal inexistent"
            e = self.validate(b, cid)
            if e: return e
            cfg = self.norm(b); cfg["id"] = cid
            ch.stop(); del self.chans[cid]; time.sleep(0.3)
            self.add(cfg); return None

    def delete(self, cid):
        with self.lock:
            ch = self.chans.pop(cid, None)
            if ch: ch.stop(); self.save(); self.ports()

    def restart(self, cid):
        with self.lock:
            ch = self.chans.get(cid)
            if ch: ch.stop(); time.sleep(0.3); ch.start(); self.ports()

    def loop(self):
        last = now()
        while True:
            time.sleep(1)
            t = now(); dt = max(0.2, t - last); last = t
            lb, seen = self.sniff.take()
            for ch in list(self.chans.values()):
                try: ch.tick(dt, lb, seen)
                except Exception as e: ch.L(f"tick: {e}")

    def status(self):
        chs = [c.status() for c in sorted(self.chans.values(), key=lambda x: x.id)]
        try: load = os.getloadavg()[0]
        except Exception: load = 0
        return {"channels": chs, "total_mbps": round(sum(c["mbps"] for c in chs), 2),
                "onair": sum(1 for c in chs if c["state"] == "ON AIR"), "load": round(load, 2),
                "ncpu": os.cpu_count(), "uptime": int(now() - self.t0), "sniffer": self.sniff.ok,
                "host": socket.gethostname()}

H_ = None
HERE = os.path.dirname(os.path.abspath(__file__))

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def auth(self):
        c = H_.conf
        tok = base64.b64encode(f"{c['web_user']}:{c['web_pass']}".encode()).decode()
        if self.headers.get("Authorization") == "Basic " + tok: return True
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="nTs-AIR RX"')
        self.send_header("Content-Length", "0"); self.end_headers(); return False
    def out(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)): body = json.dumps(body)
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        try: return json.loads(self.rfile.read(n) or b"{}")
        except Exception: return {}

    def stream(self, ch):
        internal = "thumb=1" in self.path and self.client_address[0] == "127.0.0.1"
        stream_to_client(self, ch, internal)

    def find(self, name):
        for c in H_.chans.values():
            if c.cfg["name"] == name: return c

    def do_GET(self):
        p = unquote(self.path.split("?")[0])
        m = re.match(r"^/live/([^/]+?)(?:\.ts)?$", p) or re.match(r"^/([A-Za-z0-9_.-]+)$", p)
        if m and (ch := self.find(m.group(1))):
            return self.stream(ch)
        if not self.auth(): return
        if p == "/":
            html = open(os.path.join(HERE, "rx.html"), encoding="utf-8").read()
            return self.out(200, html, "text/html; charset=utf-8")
        if p == "/api/status": return self.out(200, H_.status())
        if p == "/api/hdmi": return self.out(200, hdmi_connectors())
        if p == "/api/decklink": return self.out(200, decklink_devices())
        mt = re.match(r"^/thumb/(\d+)\.jpg$", p)
        if mt:
            try: return self.out(200, open(f"{RUN}/thumb_{int(mt.group(1))}.jpg", "rb").read(), "image/jpeg")
            except Exception: return self.out(404, b"", "image/jpeg")
        self.out(404, {"err": "not found"})

    def do_POST(self):
        if not self.auth(): return
        p = self.path; b = self.body()
        if p == "/api/channel":
            e = H_.create(b); return self.out(400 if e else 200, {"err": e} if e else {"ok": 1})
        m = re.match(r"^/api/channel/(\d+)/(update|delete|restart)$", p)
        if m:
            cid, act = int(m.group(1)), m.group(2)
            if act == "update":
                e = H_.update(cid, b); return self.out(400 if e else 200, {"err": e} if e else {"ok": 1})
            if act == "delete": H_.delete(cid)
            if act == "restart": H_.restart(cid)
            return self.out(200, {"ok": 1})
        if p == "/api/password":
            pw = str(b.get("pass", ""))
            if len(pw) < 4: return self.out(400, {"err": "Parola prea scurta"})
            H_.conf["web_pass"] = pw; save_conf(H_.conf); return self.out(200, {"ok": 1})
        self.out(404, {"err": "not found"})

def main():
    global H_
    H_ = Hub()
    def bye(*a):
        for c in H_.chans.values(): c.stop()
        os._exit(0)
    signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
    srv = ThreadingHTTPServer(("0.0.0.0", int(H_.conf["web_port"])), H)
    srv.daemon_threads = True
    print("nTs-AIR RX panel pe port", H_.conf["web_port"], flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
NTS_RXPY_EOF
cat > $BASE/rx.html <<'NTS_RXHTML_EOF'
<!DOCTYPE html>
<html lang="ro"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>nTs-AIR Receiver</title>
<style>
:root{--bg:#0d0f12;--card:#161a20;--line:#252b34;--tx:#e7eaef;--mut:#8a94a3;--acc:#2bd46b;--red:#ff4747;--yel:#f5b83d;--blue:#3aa0ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.4 system-ui,Segoe UI,Roboto,sans-serif}
header{display:flex;align-items:center;gap:18px;padding:12px 18px;border-bottom:1px solid var(--line);background:#11141a;position:sticky;top:0;z-index:5;flex-wrap:wrap}
.logo{font-weight:800;letter-spacing:.06em}.logo b{color:var(--red)}
.kpi{display:flex;gap:18px;flex-wrap:wrap}.kpi div{font-size:12px;color:var(--mut)}.kpi b{display:block;font-size:17px;color:var(--tx)}
.sp{flex:1}
button{background:#232a34;border:1px solid #2f3846;color:var(--tx);padding:7px 12px;border-radius:8px;cursor:pointer;font:inherit}
button:hover{background:#2b3440}button.p{background:var(--blue);border-color:var(--blue);color:#fff;font-weight:600}
button.d{color:#ff9a9a}
main{padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(400px,1fr));gap:16px}
@media(max-width:460px){main{grid-template-columns:1fr;padding:10px}}
.ch{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:flex;flex-direction:column}
.ch.on{border-color:#1f5a37}
.pv{position:relative;aspect-ratio:16/9;background:#05070a;display:flex;align-items:center;justify-content:center;color:#3c4654;font-weight:700;letter-spacing:.1em}
.pv img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;z-index:0}
.pv span{z-index:2;color:var(--tx)}
.pv .badge.wait{color:var(--yel)}
.badge{position:absolute;left:10px;top:10px;padding:3px 9px;border-radius:5px;font-size:12px;font-weight:800;background:#333}
.badge.on{background:var(--red);animation:pl 2s infinite}.badge.wait{background:#5a4a1b;color:var(--yel)}
@keyframes pl{50%{opacity:.75}}
.pv .br{position:absolute;right:10px;bottom:10px;background:#000b;padding:2px 10px;border-radius:6px;font-weight:800;font-size:22px}
.pv .br small{font-size:12px;color:var(--mut)}
.pv .up{position:absolute;right:10px;top:10px;background:#000b;padding:2px 8px;border-radius:5px;font:700 13px ui-monospace,monospace}
.pv .inf{position:absolute;left:10px;bottom:10px;background:#000b;padding:2px 8px;border-radius:5px;font-size:11px}
.body{padding:12px;display:flex;flex-direction:column;gap:10px}
.hd{display:flex;align-items:center;gap:8px}.hd h3{margin:0;font-size:16px}.hd .port{color:var(--mut);font-size:12px}
canvas{width:100%;height:44px;display:block}
.met{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.met div{background:#0f1217;border-radius:8px;padding:5px 7px;font-size:11px;color:var(--mut)}.met b{display:block;color:var(--tx);font-size:14px}
.met .bad b{color:var(--yel)}.met .vbad b{color:var(--red)}
h4{margin:2px 0 0;font-size:11px;letter-spacing:.08em;color:var(--mut);text-transform:uppercase;font-weight:600}
.lk{display:grid;grid-template-columns:1fr auto;gap:2px 10px;align-items:center;font-size:12px}
.lk .n{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.lk .op{font-size:10px;padding:0 6px;border-radius:8px;background:#263040;margin-left:4px}
.lk .bar{grid-column:1/3;height:5px;background:#0006;border-radius:3px;overflow:hidden;margin-bottom:4px}.lk .bar i{display:block;height:100%;background:var(--acc)}
.op.Orange{background:#5a3412;color:#ffb067}.op.Vodafone{background:#5a1616;color:#ff8d8d}.op.Digi{background:#14335a;color:#8cc4ff}.op.Telekom{background:#4a1640;color:#ff8ce0}
.outs{font-size:12px;display:flex;flex-direction:column;gap:3px}
.outs div{display:flex;gap:6px;align-items:center;word-break:break-all}
.dot{width:8px;height:8px;border-radius:50%;background:var(--acc);flex:none}.dot.x{background:var(--red)}
.outs a{color:var(--blue);text-decoration:none;cursor:pointer}
.acts{display:flex;gap:6px;flex-wrap:wrap}
pre{background:#090b0e;border-radius:8px;padding:8px;max-height:180px;overflow:auto;font-size:11px;margin:0;white-space:pre-wrap;display:none}
pre.show{display:block}
.mut{color:var(--mut);font-size:12px}
.empty{grid-column:1/-1;text-align:center;padding:60px 10px;color:var(--mut)}
dialog{background:var(--card);color:var(--tx);border:1px solid var(--line);border-radius:14px;padding:18px;width:min(520px,94vw)}
dialog::backdrop{background:#000a}
dialog label{display:block;font-size:12px;color:var(--mut);margin-top:10px}
dialog input,dialog textarea{width:100%;margin-top:3px;background:#0e1115;border:1px solid var(--line);color:var(--tx);padding:8px;border-radius:7px;font:inherit}
dialog textarea{font:12px ui-monospace,monospace;height:110px}
.row2{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}
.tpl{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px}.tpl button{font-size:12px;padding:5px 9px}
.err{color:var(--red);font-size:13px;min-height:18px;margin-top:8px}
.help{font-size:11px;color:var(--mut);margin-top:4px;line-height:1.5}
</style></head><body>
<header>
 <div class="logo">nTs-AIR <b>RX</b></div>
 <div class="kpi">
  <div>ON AIR<b id="k_on">0/0</b></div><div>Total intrare<b id="k_tot">0 Mbps</b></div>
  <div>Load<b id="k_load">-</b></div><div>Server<b id="k_host">-</b></div>
 </div>
 <div class="sp"></div>
 <button onclick="pw()">Parolă</button>
 <button class="p" onclick="edit()">+ Canal</button>
</header>
<main id="grid"></main>

<dialog id="dlg"><form method="dialog" onsubmit="return false">
 <h3 id="dt" style="margin:0">Canal nou</h3>
 <label>Nume (folosit în link: /live/NUME.ts)<input id="f_name" placeholder="cam1"></label>
 <div class="row2">
  <label>Port SRTLA (UDP)<input id="f_port" type="number" value="5000"></label>
  <label>Latență (ms)<input id="f_lat" type="number" value="2000"></label>
  <label>lossmaxttl<input id="f_ttl" type="number" value="40"></label>
 </div>
 <div class="tpl" id="tpl">
  <button type="button" onclick="addOut('http')">+ HTTP (Astra)</button>
  <button type="button" onclick="addOut('udp')">+ Multicast UDP</button>
  <button type="button" onclick="addOut('rtp')">+ Multicast RTP</button>
  <button type="button" onclick="addOut('srt')">+ SRT</button>
  <button type="button" onclick="addOut('rtmp')">+ RTMP</button>
  <button type="button" onclick="addOut('hdmi')">+ HDMI</button>
  <button type="button" onclick="addOut('decklink')">+ DeckLink SDI/HDMI</button>
 </div>
 <label>Ieșiri (câte una pe linie, max 8)<textarea id="f_out" placeholder="udp://127.0.0.1:5010&#10;udp://239.1.1.10:1234?ttl=4&#10;srt://0.0.0.0:6001?mode=listener&#10;rtmp://localhost/live/cam1"></textarea></label>
 <div class="help">HTTP-TS e mereu activ: <b>http://server:PORT/live/NUME.ts</b> și <b>/NUME</b>.<br>
  <b>http://0.0.0.0:8000/cale</b> = HTTP-TS pe port separat, ca la Astra (mai multe canale pot folosi același port cu căi diferite)<br>
  <b>udp://</b> / <b>rtp://</b> unicast sau multicast (?ttl=4&amp;localaddr=IP-placa) · <b>srt://</b> listener/caller · <b>rtmp://</b> (doar H.264)<br>
  <b>hdmi://</b> = decodare pe ecranul serverului (?connector=HDMI-A-1&amp;audio=alsa/hdmi:CARD=PCH,DEV=0) — server fizic, fără desktop pornit
  <br><b>decklink://?device=0&amp;mode=1080i50</b> = ieșire pe placa Blackmagic (moduri: 1080i50, 1080p25, 1080p50, 720p50, pal; &amp;audio=0 fără sunet)
  <div id="hdmiinfo" style="margin-top:4px"></div></div>
 <label style="display:flex;gap:8px;align-items:center;color:var(--tx)"><input type="checkbox" id="f_en" style="width:auto" checked> Activ</label>
 <div class="err" id="ferr"></div>
 <div class="acts" style="justify-content:flex-end"><button onclick="dlg.close()">Anulează</button><button class="p" onclick="saveCh()">Salvează</button></div>
</form></dialog>

<script>
const $=id=>document.getElementById(id);let S={channels:[]},editing=null,openLogs={};
const dlg=$('dlg');
const fmt=s=>[s/3600|0,(s/60|0)%60,s%60].map(x=>String(x).padStart(2,'0')).join(':');
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(p,b){const r=await fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:{});return r.json()}
function spark(cv,h,mx){const d=window.devicePixelRatio||1,w=cv.clientWidth,ht=cv.clientHeight;cv.width=w*d;cv.height=ht*d;const x=cv.getContext('2d');x.scale(d,d);
 if(!h.length)return;const m=Math.max(mx||1,...h)*1.15;x.beginPath();h.forEach((v,i)=>{const px=w-(h.length-1-i)*(w/119),py=ht-v/m*ht;i?x.lineTo(px,py):x.moveTo(px,py)});
 x.strokeStyle='#2bd46b';x.lineWidth=1.5;x.stroke();x.lineTo(w,ht);x.lineTo(w-(h.length-1)*(w/119),ht);x.closePath();x.fillStyle='#2bd46b22';x.fill()}
function card(c){
 const on=c.state=='ON AIR',wait=c.state=='ASTEAPTA';const base=location.origin;
 const lmax=Math.max(.01,...c.links.map(l=>l.mbps));const tot=c.links.reduce((a,l)=>a+l.mbps,0)||1;
 const lossCls=c.lost10>200?'vbad':c.lost10>20?'bad':'',dropCls=c.drop10>0?'vbad':'';
 return `<div class="ch ${on?'on':''}" id="ch${c.id}">
 <div class="pv">${c.thumb?`<img src="/thumb/${c.id}.jpg?${Math.floor(Date.now()/10000)}">`:(on?'':'NO SIGNAL')}
  <span class="badge ${on?'on':wait?'wait':''}">${c.state}</span>
  ${on?`<span class="up">${fmt(c.uptime)}</span>`:''}
  ${c.info.video?`<span class="inf">${esc(c.info.video)}${c.info.audio?' · '+esc(c.info.audio):''}</span>`:''}
  <span class="br">${c.mbps.toFixed(2)} <small>Mbps</small></span></div>
 <div class="body">
  <div class="hd"><h3>${esc(c.name)}</h3><span class="port">UDP ${c.srtla_port} · latență ${c.latency} ms</span></div>
  <canvas id="cv${c.id}"></canvas>
  <div class="met">
   <div>Legături<b>${c.links.length}</b></div><div>RTT<b>${c.rtt?c.rtt+' ms':'-'}</b></div>
   <div class="${lossCls}">Pierdute/10s<b>${c.lost10}</b></div><div class="${dropCls}">Drop/10s<b>${c.drop10}</b></div>
  </div>
  <h4>Legături bonded</h4>
  <div class="lk">${c.links.length?c.links.map(l=>`<span class="n" title="${esc(l.host)}">${esc(l.ip)}:${l.port}${l.op?`<span class="op ${l.op}">${l.op}</span>`:''}</span>
   <span>${l.mbps.toFixed(2)} Mbps · ${Math.round(l.mbps/tot*100)}%</span><div class="bar"><i style="width:${l.mbps/lmax*100}%"></i></div>`).join(''):'<span class="mut">niciun transmițător conectat</span>'}</div>
  <h4>Ieșiri</h4>
  <div class="outs">
   <div><span class="dot"></span><a onclick="cp('${base}/live/${esc(c.name)}.ts')">${base}/live/${esc(c.name)}.ts</a></div>
   ${c.out_status.map(o=>{const u=o.http?`http://${location.hostname}:${o.port}${o.path}`:'';
     return `<div><span class="dot ${o.ok?'':'x'}"></span>${o.http?`<a onclick="cp('${esc(u)}')" title="copiază">${esc(u)}</a>`:esc(o.url)}</div>`}).join('')}
   ${c.clients.length?`<div class="mut">Clienți HTTP: ${c.clients.map(k=>esc(k.ip)+' ('+fmt(k.since)+')').join(', ')}</div>`:''}
  </div>
  <div class="acts"><button onclick="edit(${c.id})">Editează</button><button onclick="act(${c.id},'restart')">Restart</button>
   <button onclick="tl(${c.id})">Jurnal</button><button class="d" onclick="del(${c.id},'${esc(c.name)}')">Șterge</button></div>
  <pre id="lg${c.id}" class="${openLogs[c.id]?'show':''}">${esc(c.log.join('\n'))}</pre>
 </div></div>`}
async function tick(){
 try{S=await api('/api/status')}catch(e){return}
 $('k_on').textContent=S.onair+'/'+S.channels.length;$('k_tot').textContent=S.total_mbps.toFixed(2)+' Mbps';
 $('k_load').textContent=S.load+' / '+S.ncpu+' CPU';$('k_host').textContent=S.host;
 if(dlg.open)return;
 const sc=window.scrollY;
 $('grid').innerHTML=S.channels.length?S.channels.map(card).join(''):'<div class="empty">Niciun canal. Apasă <b>+ Canal</b> pentru a adăuga un receptor pentru transmițător.</div>';
 S.channels.forEach(c=>{spark($('cv'+c.id),c.hist);const l=$('lg'+c.id);if(l)l.scrollTop=l.scrollHeight});
 window.scrollTo(0,sc);
}
function tl(id){openLogs[id]=!openLogs[id];$('lg'+id).classList.toggle('show')}
function cp(t){navigator.clipboard&&navigator.clipboard.writeText(t);}
function edit(id){
 editing=id||null;const c=S.channels.find(x=>x.id==id);$('ferr').textContent='';
 $('dt').textContent=c?'Editează '+c.name:'Canal nou';
 const used=S.channels.map(x=>x.srtla_port);let np=5000;while(used.includes(np))np++;
 $('f_name').value=c?c.name:'cam'+(S.channels.length+1);$('f_port').value=c?c.srtla_port:np;
 loadHdmi();$('f_lat').value=c?c.latency:2000;$('f_ttl').value=c?c.lossmaxttl:40;$('f_out').value=c?c.outputs.join('\n'):'';$('f_en').checked=c?c.enabled:true;
 dlg.showModal()}
let HDMI=[];
async function loadHdmi(){try{HDMI=await api('/api/hdmi')}catch(e){HDMI=[]}
 let DL=[];try{DL=await api('/api/decklink')}catch(e){}
 $('hdmiinfo').innerHTML=HDMI.length?'Ecrane: '+HDMI.map(x=>`${esc(x.connector)} (${esc(x.card)}) <b style="color:${x.status=='connected'?'var(--acc)':'var(--mut)'}">${esc(x.status)}</b>`).join(' · '):'Niciun ecran detectat pe server';
 $('hdmiinfo').innerHTML+=' · DeckLink: '+(DL.length?DL.length+' placă/plăci':'nedetectat (driver Desktop Video?)')}
function addOut(t){
 const n=$('f_name').value.trim()||'canal',ta=$('f_out');
 const used=S.channels.length+1;
 const conn=(HDMI.find(x=>x.status=='connected')||{}).connector;
 const v={http:`http://0.0.0.0:8000/${n}`,udp:`udp://239.255.1.${used}:1234?ttl=4`,rtp:`rtp://239.255.1.${used}:1234?ttl=4`,
  srt:`srt://0.0.0.0:${6000+used}?mode=listener`,rtmp:`rtmp://localhost/live/${n}`,hdmi:conn?`hdmi://?connector=${conn}`:'hdmi://auto',decklink:'decklink://?device=0&mode=1080i50'}[t];
 ta.value=(ta.value.trim()?ta.value.trim()+'\n':'')+v}
async function saveCh(){
 const b={name:$('f_name').value.trim(),srtla_port:+$('f_port').value,latency:+$('f_lat').value,lossmaxttl:+$('f_ttl').value,outputs:$('f_out').value,enabled:$('f_en').checked};
 const r=await api(editing?`/api/channel/${editing}/update`:'/api/channel',b);
 if(r.err){$('ferr').textContent=r.err;return}dlg.close();tick()}
async function act(id,a){await api(`/api/channel/${id}/${a}`,{});tick()}
function del(id,n){if(confirm('Ștergi canalul '+n+'?'))act(id,'delete')}
async function pw(){const p=prompt('Parolă nouă panou:');if(!p)return;const r=await api('/api/password',{pass:p});alert(r.err||'Parola schimbată. Reautentifică-te.')}
tick();setInterval(tick,1000);
</script></body></html>
NTS_RXHTML_EOF
chmod 755 $BASE/rx.py
}

case "$1" in
  tx) install_tx ;;
  rx) install_rx ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "Folosire: sudo bash $0 tx|rx|status|uninstall"; exit 1 ;;
esac
