# =====================================================================
#  nTs-AIR pentru Windows - transmitator bonding 4G/5G/WiFi/LAN (stil AIR220)
#  Encoder: Intel Quick Sync (QSV) / Media Foundation / x264
#
#  Rulare (PowerShell ca Administrator):
#    Set-ExecutionPolicy -Scope Process Bypass -Force
#    .\nts-air-win.ps1 -RxHost netstreaming.eu
#  Dezinstalare:
#    .\nts-air-win.ps1 -Uninstall
# =====================================================================
param(
  [string]$RxHost = "netstreaming.eu",
  [int]$RxPort = 5000,
  [int]$WebPort = 8080,
  [string]$Dir = "C:\nts-air",
  [string]$Msys = "C:\msys64",
  [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Say($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
$utf8 = New-Object System.Text.UTF8Encoding $false
function Put($path, $text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Native($exe, [string[]]$a) {   # ruleaza fara ca stderr sa devina eroare PowerShell (PS 5.1)
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  & $exe @a 2>&1 | Out-Null; $code = $LASTEXITCODE
  $ErrorActionPreference = $old; return $code
}
function Write-Sources {
  Put "$Dir\air.py" @'
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
'@
  Put "$Dir\air.html" @'
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
'@
  Put "$Dir\src\belacoder_port.c" @'
#ifndef VERSION
#define VERSION "nts-air-win"
#endif
/*
    belacoder - live video encoder with dynamic bitrate control
    Copyright (C) 2020-2026 BELABOX project

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

/* nTs-AIR: port portabil Windows (MSYS2/UCRT64) + Linux.
   Modificari fata de upstream (github.com/BELABOX/belacoder):
   - fara mmap / glib-unix / alarm(): fisierul pipeline citit cu g_file_get_contents,
     iesirea fortata dupa 3s facuta cu un thread
   - fisierul de bitrate e verificat la fiecare secunda (pe Windows nu exista SIGHUP)
   - timp monoton prin g_get_monotonic_time(); tipuri pe 64 biti pentru PTS */
#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #include <windows.h>
  #undef min
  #undef max
#else
  #include <netdb.h>
  #include <arpa/inet.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <assert.h>
#include <signal.h>

#include <gst/gst.h>
#include <gst/gstinfo.h>
#include <gst/app/gstappsink.h>

#include <srt.h>
#include <srt/access_control.h>

#define SRT_MAX_OHEAD 20     // maximum SRT transmission overhead (when using appsink)
#define SRT_ACK_TIMEOUT 6000 // maximum interval between received ACKs before the connection is TOed

#define MIN_BITRATE (300 * 1000)
#define ABS_MAX_BITRATE (30 * 1000 * 1000)
#define DEF_BITRATE (6 * 1000 * 1000)

#define BITRATE_UPDATE_INT 20
#define BITRATE_INCR_MIN       (30*1000)  // the minimum bitrate increment step (bps)
#define BITRATE_INCR_INT       500        // the minimum interval for increasing the bitrate (ms)
#define BITRATE_INCR_SCALE     30         // the bitrate is increased by
                                          // BITRATE_INCR_MIN + cur_bitrate/BITRATE_INCR_SCALE

#define BITRATE_DECR_MIN       (100*1000) // the minimum value to decrease the bitrate by (bps)
#define BITRATE_DECR_INT       200        // (light congestion) min interval for decreasing the bitrate (ms)
#define BITRATE_DECR_FAST_INT  250        // (heavy congestion) min interval for decreasing the bitrate (ms)
#define BITRATE_DECR_SCALE     10         // under heavy congestion, the bitrate is decreased by
                                          // BITRATE_DECR_MIN + cur_bitrate/BITRATE_DECR_SCALE

// settings ranges
#define TS_PKT_SIZE 188
#define REDUCED_SRT_PKT_SIZE ((TS_PKT_SIZE)*6)
#define DEFAULT_SRT_PKT_SIZE ((TS_PKT_SIZE)*7)
#define MAX_AV_DELAY 10000
#define MIN_SRT_LATENCY 100
#define MAX_SRT_LATENCY 10000
#define DEF_SRT_LATENCY 2000

#define min(a, b) ((a < b) ? a : b)
#define max(a, b) ((a > b) ? a : b)
#define min_max(a, l, h) (max(min((a), (h)), (l)))

//#define DEBUG 1
#ifdef DEBUG
  #define debug(...) fprintf (stderr, __VA_ARGS__)
#else
  #define debug(...)
#endif

static GstPipeline *gst_pipeline = NULL;
GMainLoop *loop;
GstElement *encoder, *overlay;
SRTSOCKET sock = -1;
int quit = 0;

int enc_bitrate_div = 1;

int av_delay = 0;

int min_bitrate = MIN_BITRATE;
int max_bitrate = DEF_BITRATE;
int cur_bitrate = MIN_BITRATE;

char *bitrate_filename = NULL;

int srt_latency = DEF_SRT_LATENCY;
int srt_pkt_size = DEFAULT_SRT_PKT_SIZE;

uint64_t getms() {
  return (uint64_t)(g_get_monotonic_time() / 1000);
}

static gpointer force_exit_thread(gpointer data) {
  g_usleep(3 * G_USEC_PER_SEC);
  _exit(EXIT_SUCCESS); // the pipeline failed to stop in time
  return NULL;
}

/* Attempts to stop the gstreamer pipeline cleanly
   Also sets up a timer thread in case it doesn't */
void stop() {
  if (!quit) {
    quit = 1;
    g_thread_new("force-exit", force_exit_thread, NULL);
    g_main_loop_quit(loop);
  }
}

static void stop_sig(int signum) { stop(); }

/*
  This checks periodically for pipeline stalls. The alsasrc element tends to stall rather
  than error out when the input resolution changes for a live input into a Camlink 4K
  connected to a Jetson Nano. If you see this happening in other scenarios, please report it
*/
gboolean stall_check(gpointer data) {
  /* This will handle any signals delivered between setting up the handler and
     starting the loop. Couldn't find another way to avoid races / potentially
     losing signals */
  if (quit) {
    stop();
    return TRUE;
  }

  static gint64 prev_pos = -1;
  gint64 pos;
  if (!gst_element_query_position((GstElement *)gst_pipeline, GST_FORMAT_TIME, &pos))
    return TRUE;

  if (pos != -1 && pos == prev_pos) {
    fprintf(stderr, "Pipeline stall detected. Will exit now\n");
    stop();
  }

  prev_pos = pos;
  return TRUE;
}

void update_overlay(int set_bitrate, double throughput,
                    int rtt, int rtt_th_min, int rtt_th_max,
                    int bs, int bs_th1, int bs_th2, int bs_th3) {
  if (GST_IS_ELEMENT(overlay)) {
    char overlay_text[100];
    snprintf(overlay_text, 100, "  b: %5d/%5.0f rtt: %3d/%3d/%3d bs: %3d/%3d/%3d/%3d",
             set_bitrate/1000, throughput,
             rtt, rtt_th_min, rtt_th_max,
             bs, bs_th1, bs_th2, bs_th3);
    g_object_set (G_OBJECT(overlay), "text", overlay_text, NULL);
  }
}

int parse_bitrate(char *bitrate_string) {
  int bitrate = strtol(bitrate_string, NULL, 10);
  if (bitrate < MIN_BITRATE || bitrate > ABS_MAX_BITRATE) {
    return -1;
  }
  return bitrate;
}

static gchar *bitrate_file_prev = NULL;

int read_bitrate_file() {
  gchar *content = NULL;
  if (!g_file_get_contents(bitrate_filename, &content, NULL, NULL)) return -1;

  int br[2];
  char *p = content, *end;
  for (int i = 0; i < 2; i++) {
    while (*p == '\r' || *p == '\n' || *p == ' ') p++;
    br[i] = strtol(p, &end, 10);
    if (end == p || br[i] < MIN_BITRATE || br[i] > ABS_MAX_BITRATE) {
      g_free(content);
      return -2;
    }
    p = end;
  }

  g_free(bitrate_file_prev);
  bitrate_file_prev = content;
  min_bitrate = br[0];
  max_bitrate = br[1];
  return 0;
}

/* Portable replacement for SIGHUP: reload the bitrate file when its content changes */
gboolean bitrate_file_check(gpointer data) {
  gchar *content = NULL;
  if (!bitrate_filename || !g_file_get_contents(bitrate_filename, &content, NULL, NULL)) return TRUE;
  int changed = (bitrate_file_prev == NULL || strcmp(content, bitrate_file_prev) != 0);
  g_free(content);
  if (changed && read_bitrate_file() == 0) {
    fprintf(stderr, "Bitrate settings reloaded: %d - %d\n", min_bitrate, max_bitrate);
  }
  return TRUE;
}

#ifndef _WIN32
static void sighup_handler(int signum) { if (bitrate_filename) read_bitrate_file(); }
#endif

#define RTT_TO_BS(rtt) ((throughput / 8) * (rtt) / srt_pkt_size)
void update_bitrate(SRT_TRACEBSTATS *stats, uint64_t ctime) {
  /*
   * Send buffer size stats
   */
  int bs = -1;
  int sz = sizeof(bs);
  int ret = srt_getsockflag(sock, SRTO_SNDDATA, &bs, &sz);
  if (ret != 0 || bs < 0) return;

  // Rolling average
  static double bs_avg = 0;
  bs_avg = bs_avg*0.99 + (double)bs * 0.01;

  // Update the buffer size jitter
  static double bs_jitter = 0;
  static int prev_bs = 0;
  bs_jitter = 0.99 * bs_jitter;
  int delta_bs = bs - prev_bs;
  if (delta_bs > bs_jitter) {
    bs_jitter = (double)delta_bs;
  }
  prev_bs = bs;


  /*
   * RTT stats
   */
  int rtt = (int)stats->msRTT;

  // Update the average RTT
  static double rtt_avg = 0;
  if (rtt_avg == 0.0) {
    rtt_avg = (double)rtt;
  } else {
    rtt_avg = rtt_avg * 0.99 + 0.01 * (double)rtt;
  }

  // Update the average RTT delta
  static double rtt_avg_delta = 0;
  static int prev_rtt = 300;
  double delta_rtt = (double)(rtt - prev_rtt);
  rtt_avg_delta = rtt_avg_delta * 0.8 + delta_rtt * 0.2;
  prev_rtt = rtt;

  // Update the minimum RTT
  static double rtt_min = 200.0;
  rtt_min *= 1.001;
  if (rtt != 100 && rtt < rtt_min && rtt_avg_delta < 1.0) {
    rtt_min = rtt;
  }

  // Update the RTT jitter
  static double rtt_jitter = 0;
  rtt_jitter *= 0.99;
  if (delta_rtt > rtt_jitter) {
    rtt_jitter = delta_rtt;
  }


  /*
   * Rolling average of the network throughput
   */
  static double throughput = 0.0;
  throughput *= 0.97;
  throughput += ((double)stats->mbpsSendRate * 1000.0 * 1000.0 / 1024.0) * 0.03;


  debug("bs: %d bs_avg: %f, bs_jitter %f, bitrate %d rtt %d, delta rtt %.0f, avg delta %.1f, avg rtt %.1f, rtt_jitter, %.2f, rtt_min %.1f\n",
        bs, bs_avg, bs_jitter, cur_bitrate, rtt, delta_rtt, rtt_avg_delta, rtt_avg, rtt_jitter, rtt_min);


  static uint64_t next_bitrate_incr = 0;
  static uint64_t next_bitrate_decr = 0;

  int bitrate = cur_bitrate;
  int bs_th3 = (bs_avg + bs_jitter)*4;
  int bs_th2 = max(50, bs_avg + max(bs_jitter*3.0, bs_avg));
  bs_th2 = min(bs_th2, RTT_TO_BS(srt_latency/2));
  int bs_th1 = max(50, bs_avg + bs_jitter*2.5);
  int rtt_th_max = rtt_avg + max(rtt_jitter*4, rtt_avg*15/100);
  int rtt_th_min = rtt_min + max(1, rtt_jitter*2);


  if (bitrate > min_bitrate && (rtt >= (srt_latency / 3) || bs > bs_th3)) {
    bitrate = min_bitrate;
    next_bitrate_decr = ctime + BITRATE_DECR_INT;

  } else if (ctime > next_bitrate_decr &&
      (rtt > (srt_latency / 5) || bs > bs_th2)) {
    bitrate -= BITRATE_DECR_MIN + bitrate/BITRATE_DECR_SCALE;
    next_bitrate_decr = ctime + BITRATE_DECR_FAST_INT;

  } else if (ctime > next_bitrate_decr &&
             (rtt > rtt_th_max || bs > bs_th1)) {
    bitrate -= BITRATE_DECR_MIN;
    next_bitrate_decr = ctime + BITRATE_DECR_INT;

  } else if (ctime > next_bitrate_incr &&
             rtt < rtt_th_min && rtt_avg_delta < 0.01) {
    bitrate += BITRATE_INCR_MIN + bitrate / BITRATE_INCR_SCALE;
    next_bitrate_incr = ctime + BITRATE_INCR_INT;
  }

  bitrate = min_max(bitrate, min_bitrate, max_bitrate);

  // round the bitrate we set to 100 kbps
  int rounded_br = bitrate / (100*1000) * (100*1000);

  update_overlay(rounded_br, throughput, rtt, rtt_th_min, rtt_th_max, bs, bs_th1, bs_th2, bs_th3);

  if (bitrate != cur_bitrate) {
    cur_bitrate = bitrate;

    g_object_set (G_OBJECT(encoder), "bitrate", rounded_br / enc_bitrate_div, NULL);

    debug("set bitrate to %d, internal value %d\n", rounded_br, cur_bitrate);
  }
}

gboolean connection_housekeeping() {
  uint64_t ctime = getms();
  static uint64_t prev_ack_ts = 0;
  static uint64_t prev_ack_count = 0;

  // SRT stats
  SRT_TRACEBSTATS stats;
  int ret = srt_bstats(sock, &stats, 1);
  if (ret != 0) goto r;

  // Track when the most recent ACK was received
  if (stats.pktRecvACKTotal != prev_ack_count) {
    prev_ack_count = stats.pktRecvACKTotal;
    prev_ack_ts = ctime;
  }
  /* Manual check for connection timeout, because SRT is Pepega
     and will fail to timeout if RTT was high */
  if (prev_ack_count != 0 && (ctime - prev_ack_ts) > SRT_ACK_TIMEOUT) {
    fprintf(stderr, "The SRT connection timed out, exiting\n");
    stop();
  }

  // We can only update the bitrate when we have a configurable encoder
  if (GST_IS_ELEMENT(encoder)) {
    update_bitrate(&stats, ctime);
  }

r:
  return TRUE;
}

GstFlowReturn new_buf_cb(GstAppSink *sink, gpointer user_data) {
  static char pkt[DEFAULT_SRT_PKT_SIZE];
  static int pkt_len = 0;
  GstFlowReturn code = GST_FLOW_OK;

  GstSample *sample = gst_app_sink_pull_sample(sink);
  if (!sample) return GST_FLOW_ERROR;

  GstBuffer *buffer = NULL;
  GstMapInfo map = {0};

  buffer = gst_sample_get_buffer(sample);
  gst_buffer_map(buffer, &map, GST_MAP_READ);

  // We send srt_pkt_size size packets, splitting and merging samples if needed
  int sample_sz = map.size;
  do {
    int copy_sz = min(srt_pkt_size - pkt_len, sample_sz);
    memcpy((void *)pkt + pkt_len, map.data, copy_sz);
    pkt_len += copy_sz;

    if (pkt_len == srt_pkt_size) {
      int nb = srt_send(sock, pkt, srt_pkt_size);
      if (nb != srt_pkt_size) {
        if (!quit) {
          fprintf(stderr, "The SRT connection failed, exiting\n");
          stop();
        }
        code = GST_FLOW_ERROR;
        goto ret;
      }
      pkt_len = 0;
    }

    sample_sz -= copy_sz;
  } while(sample_sz);

ret:
  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);

  return code;
}

int connect_srt(char *host, char *port, char *stream_id) {
  struct addrinfo hints;
  struct addrinfo *addrs;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  int ret = getaddrinfo(host, port, &hints, &addrs);
  if (ret != 0) return -1;

  sock = srt_create_socket();
  if (sock == SRT_INVALID_SOCK) return -2;

#if SRT_MAX_OHEAD > 0
  // auto, based on input rate
  int64_t max_bw = 0;
  ret = srt_setsockflag(sock, SRTO_MAXBW, &max_bw, sizeof(max_bw));
  assert(ret == 0);

  // overhead(retransmissions)
  int32_t ohead = SRT_MAX_OHEAD;
  ret = srt_setsockflag(sock, SRTO_OHEADBW, &ohead, sizeof(ohead));
  assert(ret == 0);
#endif

  ret = srt_setsockflag(sock, SRTO_LATENCY, &srt_latency, sizeof(srt_latency));
  assert(ret == 0);

  if (stream_id != NULL) {
    ret = srt_setsockflag(sock, SRTO_STREAMID, stream_id, strlen(stream_id));
    assert(ret == 0);
  }

  int32_t algo = 1;
  ret = srt_setsockflag(sock, SRTO_RETRANSMITALGO, &algo, sizeof(algo));
  assert(ret == 0);

  int connected = -3;
  for (struct addrinfo *addr = addrs; addr != NULL; addr = addr->ai_next) {
    ret = srt_connect(sock, addr->ai_addr, addr->ai_addrlen);
    if (ret == 0) {
      connected = 0;

      int len = sizeof(srt_latency);
      ret = srt_getsockflag(sock, SRTO_PEERLATENCY, &srt_latency, &len);
      assert(ret == 0);
      fprintf(stderr, "SRT connected to %s:%s. Negotiated latency: %d ms\n",
              host, port, srt_latency);
      break;
    }
    connected = srt_getrejectreason(sock);
  }
  freeaddrinfo(addrs);

  return connected;
}

void exit_syntax() {
  fprintf(stderr, "Syntax: belacoder PIPELINE_FILE ADDR PORT [options]\n\n");
  fprintf(stderr, "Options:\n");
  fprintf(stderr, "  -v                  Print the version and exit\n");
  fprintf(stderr, "  -d <delay>          Audio-video delay in milliseconds\n");
  fprintf(stderr, "  -s <streamid>       SRT stream ID\n");
  fprintf(stderr, "  -l <latency>        SRT latency in milliseconds\n");
  fprintf(stderr, "  -r                  Reduced SRT packet size\n");
  fprintf(stderr, "  -b <bitrate file>   Bitrate settings file, see below\n\n");
  fprintf(stderr, "Bitrate settings file syntax:\n");
  fprintf(stderr, "MIN BITRATE (bps)\n");
  fprintf(stderr, "MAX BITRATE (bps)\n---\n");
  fprintf(stderr, "example for 500 Kbps - 60000 Kbps:\n\n");
  fprintf(stderr, "    printf \"500000\\n6000000\" > bitrate_file\n\n");
  fprintf(stderr, "---\n");
  fprintf(stderr, "Send SIGHUP to reload the bitrate settings while running.\n");
  exit(EXIT_FAILURE);
}

static void cb_delay (GstElement *identity, GstBuffer *buffer, gpointer data) {
  buffer = gst_buffer_make_writable(buffer);
  GST_BUFFER_PTS (buffer) += GST_SECOND * abs(av_delay) / 1000;
}

static int get_sink_framerate(GstElement *element, gint *numerator, gint *denominator) {
  int ret = -1;

  GstPad *pad = gst_element_get_static_pad(element, "sink");
  if (!pad) {
    return -1;
  }

  GstCaps *caps = gst_pad_get_current_caps(pad);
  if (caps != NULL) {
    if (gst_caps_is_fixed(caps)) {
      const GstStructure *str = gst_caps_get_structure (caps, 0);
      if (gst_structure_get_fraction(str, "framerate", numerator, denominator)) {
        ret = 0;
      }
    }

    gst_caps_unref(caps);
  }

  gst_object_unref(pad);
  return ret;
}

guint64 pts = 0;
static void cb_ptsfixup(GstElement *identity, GstBuffer *buffer, gpointer data) {
  static gint64 period = 0;
  static gint64 prev_pts = 0;
  gint64 input_pts = GST_BUFFER_PTS(buffer);

  // get rid of the DTS, the following elements should use the PTS
  GST_BUFFER_DTS(buffer) = 0;

  // First frame, obtain the framerate and initial PTS
  if (pts == 0) {
    int fr_numerator = 0, fr_denominator = 0;
    if (get_sink_framerate(identity, &fr_numerator, &fr_denominator) == 0) {
      pts = input_pts;
      period = GST_SECOND * fr_denominator / fr_numerator;
      printf("%s: framerate: %d / %d, period is %lld\n",
             __FUNCTION__, fr_numerator, fr_denominator, (long long)period);
    }

  // Subsequent frames, adjust the PTS
  } else {
    #define AVG_MULT 1000
    #define AVG_WEIGHT 3 // AVG_WEIGHT out of AVG_MULT
    #define AVG_PREV (AVG_MULT-AVG_WEIGHT)
    #define AVG_ROUNDING (AVG_MULT/2)
    /* Rolling average to account for slight differences from the nominal framerate
       and even slight drifting over time due to temperature or voltage variation
       Have to add AVG_ROUNDING to avoid precision loss due to dividing by AVG_MULT
    */
    period = (period * AVG_PREV + AVG_ROUNDING) / AVG_MULT +
             ((input_pts - prev_pts) * AVG_WEIGHT + AVG_ROUNDING)/ AVG_MULT;

    /* As long as the input PTS is within 0 to 2.0 periods of the previous
       output PTS, assume that it was a continuous read at period ns from
       the previous frame and increment the PTS accordingly. Otherwise, handle
       the discontinuity by either dropping an input buffer or skipping an
       output period, as needed. */
    gint64 diff = input_pts - (gint64)pts;
    gint64 incr = (diff/2 + period) / period * period;
    if (incr > 0) {
      pts += incr;
      debug("%s: in pts: %lu, out pts: %lu, incr %ld, diff %ld, period %ld\n",
             __FUNCTION__, GST_BUFFER_PTS(buffer), pts, incr, diff, period);
      GST_BUFFER_PTS(buffer) = pts;
    } else {
      debug("skipping frame: pts %lu, prev pts %lu, output pts: %lu, diff %ld\n",
             input_pts, prev_pts, pts, diff);
      GST_BUFFER_FLAG_SET(buffer, GST_BUFFER_FLAG_DROPPABLE);
    }
  }

  prev_pts = input_pts;
}

void cb_pipeline (GstBus *bus, GstMessage *message, gpointer user_data) {
  switch(GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_ERROR:
      fprintf(stderr, "gstreamer error from %s\n", message->src->name);
      stop();
      break;
    case GST_MESSAGE_EOS:
      fprintf(stderr, "gstreamer eos from %s\n", message->src->name);
      stop();
      break;
    default:
      break;
  }
}

#define FIXED_ARGS 3
int main(int argc, char** argv) {
  int opt;
  char *srt_host = NULL;
  char *srt_port = NULL;
  char *stream_id = NULL;
  srt_latency = DEF_SRT_LATENCY;

  while ((opt = getopt(argc, argv, "d:b:s:l:rv")) != -1) {
    switch (opt) {
      case 'b':
        bitrate_filename = optarg;
        break;
      case 'd':
        av_delay = strtol(optarg, NULL, 10);
        if (av_delay < -MAX_AV_DELAY || av_delay > MAX_AV_DELAY) {
          fprintf(stderr, "Maximum sound delay +/- %d\n\n", MAX_AV_DELAY);
          exit_syntax();
        }
        break;
      case 's':
        stream_id = optarg;
        break;
      case 'l':
        srt_latency = strtol(optarg, NULL, 10);
        if (srt_latency < MIN_SRT_LATENCY || srt_latency > MAX_SRT_LATENCY) {
          fprintf(stderr, "The SRT latency must be between %d and %d ms\n\n",
                  MIN_SRT_LATENCY, MAX_SRT_LATENCY);
          exit_syntax();
        }
        break;
      case 'r':
        srt_pkt_size = REDUCED_SRT_PKT_SIZE;
        break;
      case 'v':
        printf(VERSION "\n");
        exit(EXIT_SUCCESS);
      default:
        exit_syntax();
    }
  }

  if (argc - optind != FIXED_ARGS) {
    exit_syntax();
  }


  setvbuf(stdout, NULL, _IONBF, 0);
  // Read the pipeline file
  gchar *launch_string = NULL;
  gsize len = 0;
  if (!g_file_get_contents(argv[optind], &launch_string, &len, NULL)) {
    fprintf(stderr, "Failed to open the pipeline file %s\n", argv[optind]);
    exit(EXIT_FAILURE);
  }
  if (len == 0) {
    fprintf(stderr, "The pipeline file is empty, exiting\n");
    exit(EXIT_FAILURE);
  }
  fprintf(stderr, "Gstreamer pipeline: %s\n", launch_string);

  gst_init (&argc, &argv);
  GError *error = NULL;
  gst_pipeline  = (GstPipeline*) gst_parse_launch(launch_string, &error);
  if (gst_pipeline == NULL) {
    g_print( "Failed to parse launch: %s\n", error->message);
    return -1;
  }
  if (error) g_error_free(error);
  GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(gst_pipeline));
  gst_bus_add_signal_watch(bus);
  g_signal_connect(bus, "message", (GCallback)cb_pipeline, gst_pipeline);


  // Optional dynamic video bitrate
  if (bitrate_filename) {
    int ret;
    if ((ret = read_bitrate_file()) != 0) {
      if (ret == -1) {
        fprintf(stderr, "Failed to read the bitrate settings file %s\n", bitrate_filename);
      } else {
        fprintf(stderr, "Failed to read valid bitrate settings from %s\n", bitrate_filename);
      }
      exit_syntax();
    }
  }
  cur_bitrate = max_bitrate;
  fprintf(stderr, "Max bitrate: %d\n", max_bitrate);
#ifndef _WIN32
  signal(SIGHUP, sighup_handler);
#endif
  if (bitrate_filename) g_timeout_add(1000, bitrate_file_check, NULL);

  encoder = gst_bin_get_by_name(GST_BIN(gst_pipeline), "venc_bps");
  if (!GST_IS_ELEMENT(encoder)) {
    encoder = gst_bin_get_by_name(GST_BIN(gst_pipeline), "venc_kbps");
    enc_bitrate_div = 1000;
  }
  if (GST_IS_ELEMENT(encoder)) {
    g_object_set (G_OBJECT(encoder), "bitrate", cur_bitrate / enc_bitrate_div, NULL);
  } else {
    fprintf(stderr, "Failed to get an encoder element from the pipeline, "
                    "no dynamic bitrate control\n");
    encoder = NULL;
  }


  // Optional bitrate overlay
  overlay = gst_bin_get_by_name(GST_BIN(gst_pipeline), "overlay");
  update_overlay(0,0,0,0,0,0,0,0,0);


  // Optional sound delay via an identity element
  fprintf(stderr, "A-V delay: %d ms\n", av_delay);
  GstElement *identity_elem = gst_bin_get_by_name(GST_BIN(gst_pipeline), av_delay >= 0 ? "a_delay" : "v_delay");
  if (GST_IS_ELEMENT(identity_elem)) {
    g_object_set(G_OBJECT(identity_elem), "signal-handoffs", TRUE, NULL);
    g_signal_connect(identity_elem, "handoff", G_CALLBACK(cb_delay), NULL);
  } else {
    fprintf(stderr, "Failed to get a delay element from the pipeline, not applying a delay\n");
  }


  // Optional video PTS interval fixup
  // To avoid OBS dropping frames due to PTS jitter
  identity_elem = gst_bin_get_by_name(GST_BIN(gst_pipeline), "ptsfixup");
  if (GST_IS_ELEMENT(identity_elem)) {
    g_object_set(G_OBJECT(identity_elem), "signal-handoffs", TRUE, NULL);
    g_signal_connect(identity_elem, "handoff", G_CALLBACK(cb_ptsfixup), NULL);
  } else {
    fprintf(stderr, "Failed to get a ptsfixup element from the pipeline, "
                    "not removing PTS jitter\n");
  }


  // Optional SRT streaming via an appsink (needed for dynamic video bitrate)
  GstAppSinkCallbacks callbacks = {NULL, NULL, new_buf_cb};
  GstElement *srt_app_sink = gst_bin_get_by_name(GST_BIN(gst_pipeline), "appsink");
  if (GST_IS_ELEMENT(srt_app_sink)) {
    gst_app_sink_set_callbacks (GST_APP_SINK(srt_app_sink), &callbacks, NULL, NULL);
    srt_host = argv[optind+1];
    srt_port = argv[optind+2];

    srt_startup();
  }

  if (GST_IS_ELEMENT(srt_app_sink)) {
    int ret_srt;
    do {
      ret_srt = connect_srt(srt_host, srt_port, stream_id);
      if (ret_srt != 0) {
        char *reason = NULL;
        switch (ret_srt) {
          case SRT_REJ_TIMEOUT:
            reason = "connection timed out";
            break;
          case SRT_REJX_CONFLICT:
            reason = "streamid already in use";
            break;
          case SRT_REJX_FORBIDDEN:
            reason = "invalid streamid";
            break;
          case -1:
            reason = "failed to resolve address";
            break;
          case -2:
            reason = "failed to open the SRT socket";
            break;
          default:
            reason = "unknown";
            break;
        }
        fprintf(stderr, "Failed to establish an SRT connection: %s. Retrying...\n", reason);
        g_usleep(500*1000);
      }
    } while(ret_srt != 0);
  }

  // We can only monitor the connection when we use an appsink
  if (GST_IS_ELEMENT(srt_app_sink)) {
    g_timeout_add(BITRATE_UPDATE_INT, connection_housekeeping, NULL);
  }

  /*
    We used to attempt to restart the pipeline in case of errors
    However the version of flvdemux distributed with Ubuntu 18.04
    for the Jetson Nano fails to restart.
    Rather than deal with glitchy pipeline elements, just give up
    and exit. Ensure you run belacoder in a wrapper script which
    can restart it if needed, e.g. belaUI
  */
  loop = g_main_loop_new (NULL, FALSE);
  signal(SIGTERM, stop_sig);
  signal(SIGINT, stop_sig);
  g_timeout_add(2000, stall_check, NULL); // check every second

  // Everything good so far, start the gstreamer pipeline
  gst_element_set_state((GstElement*)gst_pipeline, GST_STATE_PLAYING);
  g_main_loop_run(loop);

  /*
    Close the SRT socket, if connected
    This must be done before trying to stop the pipeline, as the latter
    may block, causing cb_sigalarm to terminate the process
  */
  if (sock >= 0) {
    srt_close(sock);
  }

  gst_element_set_state((GstElement*)gst_pipeline, GST_STATE_NULL);

  return 0;
}
'@
  Put "$Dir\src\srtla_send_port.c" @'
#ifndef VERSION
#define VERSION "nts-air-win"
#endif
/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2020-2021 BELABOX project

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

/* nTs-AIR: port portabil Windows (Winsock) + Linux.
   Modificari fata de upstream (github.com/BELABOX/srtla):
   - Winsock, SIO_UDP_CONNRESET dezactivat, socket non-blocking via ioctlsocket
   - reincarcarea listei de IP-uri: fisierul e verificat la fiecare secunda
     (pe Windows nu exista SIGHUP; pe Linux SIGHUP functioneaza in continuare)
   - getline / urandom / clock_gettime inlocuite cu echivalente portabile */
#ifdef _WIN32
  #define _CRT_RAND_S
  #define FD_SETSIZE 256
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #include <windows.h>
  #include <mstcpip.h>
  typedef SOCKET sock_t;
  #define BAD_SOCK INVALID_SOCKET
  #define close_sock closesocket
  #ifndef SIO_UDP_CONNRESET
  #define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
  #endif
#else
  #include <unistd.h>
  #include <signal.h>
  #include <netdb.h>
  #include <fcntl.h>
  #include <sys/types.h>
  #include <sys/socket.h>
  #include <sys/select.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  typedef int sock_t;
  #define BAD_SOCK (-1)
  #define close_sock close
#endif
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#define be16toh_(x) ntohs(x)
#define htobe16_(x) htons(x)
#define be32toh_(x) ntohl(x)

#define MTU 1500

#define SRT_TYPE_HANDSHAKE   0x8000
#define SRT_TYPE_ACK         0x8002
#define SRT_TYPE_NAK         0x8003
#define SRT_TYPE_SHUTDOWN    0x8005

#define SRTLA_TYPE_KEEPALIVE 0x9000
#define SRTLA_TYPE_ACK       0x9100
#define SRTLA_TYPE_REG1      0x9200
#define SRTLA_TYPE_REG2      0x9201
#define SRTLA_TYPE_REG3      0x9202
#define SRTLA_TYPE_REG_ERR   0x9210
#define SRTLA_TYPE_REG_NGP   0x9211
#define SRTLA_TYPE_REG_NAK   0x9212

#define SRT_MIN_LEN          16

#define SRTLA_ID_LEN         256
#define SRTLA_TYPE_REG1_LEN  (2 + (SRTLA_ID_LEN))
#define SRTLA_TYPE_REG2_LEN  (2 + (SRTLA_ID_LEN))
#define SRTLA_TYPE_REG3_LEN  2

#define LOG_NONE    0   // prints only fatal errors
#define LOG_ERR     1   // prints errors we can tolerate
#define LOG_INFO    2   // prints informational messages
#define LOG_DEBUG   3   // prints potentially verbose messages about the internal workings

#define LOG_LEVEL LOG_INFO

#if LOG_LEVEL >= LOG_DEBUG
  #define debug(...) fprintf(stderr, __VA_ARGS__)
#else
  #define debug(...)
#endif

#if LOG_LEVEL >= LOG_INFO
  #define info(...) fprintf(stderr, __VA_ARGS__)
#else
  #define info(...)
#endif

#if LOG_LEVEL >= LOG_ERR
  #define err(...) fprintf(stderr, __VA_ARGS__)
#else
  #define err(...)
#endif


void print_help();
void exit_help();

static uint64_t mono_ms(void) {
#ifdef _WIN32
  return (uint64_t)GetTickCount64();
#else
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static void set_nonblock(sock_t fd) {
#ifdef _WIN32
  u_long m = 1; ioctlsocket(fd, FIONBIO, &m);
  BOOL f = FALSE; DWORD r = 0;
  WSAIoctl(fd, SIO_UDP_CONNRESET, &f, sizeof(f), NULL, 0, &r, NULL, NULL);
#else
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
#endif
}

static void random_bytes(char *buf, int n) {
#ifdef _WIN32
  for (int i = 0; i < n; i += 4) {
    unsigned int r; rand_s(&r);
    memcpy(buf + i, &r, (n - i) < 4 ? (n - i) : 4);
  }
#else
  FILE *f = fopen("/dev/urandom", "rb");
  assert(f != NULL);
  assert(fread(buf, 1, n, f) == (size_t)n);
  fclose(f);
#endif
}

/* citeste tot fisierul (max 64KB); 0 = ok */
static int read_whole(const char *fn, char *buf, size_t sz) {
  FILE *f = fopen(fn, "rb");
  if (!f) return -1;
  size_t n = fread(buf, 1, sz - 1, f);
  buf[n] = 0; fclose(f);
  return 0;
}
void exit_help() {
  print_help();
  exit(EXIT_FAILURE);
}

#define ADDR_BUF_SZ 50
char _global_addr_buf[ADDR_BUF_SZ];
const char *print_addr(struct sockaddr *addr) {
  struct sockaddr_in *ain = (struct sockaddr_in *)addr;
  return inet_ntop(ain->sin_family, &ain->sin_addr, _global_addr_buf, ADDR_BUF_SZ);
}

int port_no(struct sockaddr *addr) {
  struct sockaddr_in *ain = (struct sockaddr_in *)addr;
  return ntohs(ain->sin_port);
}

int parse_ip(struct sockaddr_in *addr, char *ip_str) {
  while (*ip_str == ' ' || *ip_str == '\t') ip_str++;
  char *e = ip_str + strlen(ip_str);
  while (e > ip_str && (e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
  if (!*ip_str) return -1;
  unsigned long ip = inet_addr(ip_str);
  if (ip == INADDR_NONE) return -1;

  memset(addr, 0, sizeof(*addr));
  addr->sin_family = AF_INET;
  addr->sin_addr.s_addr = ip;

  return 0;
}

int parse_port(char *port_str) {
  int port = strtol(port_str, NULL, 10);
  if (port <= 0 || port > 65535) return -2;
  return port;
}

int get_seconds(time_t *s) { *s = (time_t)(mono_ms() / 1000); return 0; }
int get_ms(uint64_t *ms) { *ms = mono_ms(); return 0; }

int32_t get_srt_sn(void *pkt, int n) {
  if (n < 4) return -1;

  uint32_t sn = be32toh_(*((uint32_t *)pkt));
  if ((sn & (1 << 31)) == 0) {
    return (int32_t)sn;
  }

  return -1;
}

uint16_t get_srt_type(void *pkt, int n) {
  if (n < 2) return 0;
  return be16toh_(*((uint16_t *)pkt));
}

int is_srt_ack(void *pkt, int n) {
  return get_srt_type(pkt, n) == SRT_TYPE_ACK;
}

int is_srtla_keepalive(void *pkt, int n) {
  return get_srt_type(pkt, n) == SRTLA_TYPE_KEEPALIVE;
}

int is_srtla_reg1(void *pkt, int len) {
  if (len != SRTLA_TYPE_REG1_LEN) return 0;
  return get_srt_type(pkt, len) == SRTLA_TYPE_REG1;
}

int is_srtla_reg2(void *pkt, int len) {
  if (len != SRTLA_TYPE_REG2_LEN) return 0;
  return get_srt_type(pkt, len) == SRTLA_TYPE_REG2;
}

int is_srtla_reg3(void *pkt, int len) {
  if (len != SRTLA_TYPE_REG3_LEN) return 0;
  return get_srt_type(pkt, len) == SRTLA_TYPE_REG3;
}
#define PKT_LOG_SZ 256
#define CONN_TIMEOUT 4
#define REG2_TIMEOUT 4
#define REG3_TIMEOUT 4
#define GLOBAL_TIMEOUT 10
#define IDLE_TIME 1

#define SEND_BUF_SIZE (8 * 1024 * 1024)

#undef min
#undef max
#define min(a, b) ((a < b) ? a : b)
#define max(a, b) ((a > b) ? a : b)
#define min_max(a, l, h) (max(min((a), (h)), (l)))

#define WINDOW_MIN 1
#define WINDOW_DEF 20
#define WINDOW_MAX 60
#define WINDOW_MULT 1000
#define WINDOW_DECR 100
#define WINDOW_INCR 30

#define LOG_PKT_INT 20

typedef struct conn {
  struct conn *next;
  sock_t fd;
  time_t last_rcvd;
  time_t last_sent;
  struct sockaddr src;
  int removed;
  int in_flight_pkts;
  int window;
  int pkt_idx;
  int pkt_log[PKT_LOG_SZ];
} conn_t;

char *source_ip_file = NULL;

int do_update_conns = 0;

struct addrinfo *addrs;

struct sockaddr srtla_addr, srt_addr;
const socklen_t addr_len = sizeof(srtla_addr);
conn_t *conns = NULL;
sock_t listenfd;
int active_connections = 0;
int has_connected = 0;

conn_t *pending_reg2_conn = NULL;
time_t pending_reg_timeout = 0;

char srtla_id[SRTLA_ID_LEN];


/*

Async I/O support

*/
fd_set active_fds;
int add_active_fd(sock_t fd) {
  if (fd == BAD_SOCK) return -1;

  FD_SET(fd, &active_fds);

  return 0;
}

int remove_active_fd(sock_t fd) {
  if (fd == BAD_SOCK) return -1;

  FD_CLR(fd, &active_fds);

  return 0;
}


/*

Misc helper functions

*/
void print_help() {
  fprintf(stderr,
          "Syntax: srtla_send SRT_LISTEN_PORT SRTLA_HOST SRTLA_PORT BIND_IPS_FILE\n\n"
          "-v      Print the version and exit\n");
}


/*

srtla registration helpers

*/
int send_reg1(conn_t *c) {
  if (c->fd == BAD_SOCK) return -1;

  char buf[MTU];
  uint16_t packet_type = htobe16_(SRTLA_TYPE_REG1);
  memcpy(buf, &packet_type, sizeof(packet_type));
  memcpy(buf + sizeof(packet_type), srtla_id, SRTLA_ID_LEN);

  int ret = sendto(c->fd, (const char *)buf, SRTLA_TYPE_REG1_LEN, 0, &srtla_addr, addr_len);
  if (ret != SRTLA_TYPE_REG1_LEN) return -1;

  return 0;
}

int send_reg2(conn_t *c) {
  if (c->fd == BAD_SOCK) return -1;

  char buf[SRTLA_TYPE_REG2_LEN];
  uint16_t packet_type = htobe16_(SRTLA_TYPE_REG2);
  memcpy(buf, &packet_type, sizeof(packet_type));
  memcpy(buf + sizeof(packet_type), srtla_id, SRTLA_ID_LEN);

  int ret = sendto(c->fd, (const char *)buf, SRTLA_TYPE_REG2_LEN, 0, &srtla_addr, addr_len);
  return (ret == SRTLA_TYPE_REG2_LEN) ? 0 : -1;
}


/*

Handling code for packets coming from the SRT caller

*/
void reg_pkt(conn_t *c, int32_t packet) {
  debug("%s (%p): register packet %d at idx %d\n",
        print_addr(&c->src), c, packet, c->pkt_idx);
  c->pkt_log[c->pkt_idx] = packet;
  c->pkt_idx++;
  c->pkt_idx %= PKT_LOG_SZ;

  c->in_flight_pkts++;
}

int conn_timed_out(conn_t *c, time_t ts) {
  return (c->last_rcvd + CONN_TIMEOUT) < ts;
}

conn_t *select_conn() {
  conn_t *min_c = NULL;
  int max_score = -1;
  int max_window = 0;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->window > max_window) {
      max_window = c->window;
    }
  }

  time_t t;
  assert(get_seconds(&t) == 0);

  for (conn_t *c = conns; c != NULL; c = c->next) {
    /* If we have some very slow links, we may be better off ignoring them
       However, we'd probably need to periodically re-probe them, otherwise
       a link disabled due to a momentary glitch might not ever get enabled
       again unless all the remaining links suffered from high packet loss
       at some point. */
    /*if (c->window < max_window / 5) {
      c->window++;
      continue;
    }*/

    if (conn_timed_out(c, t)) {
      debug("%s (%p): is timed out, ignoring it\n", print_addr(&c->src), c);
      continue;
    }

    int score = c->window / (c->in_flight_pkts + 1);
    if (score > max_score) {
      min_c = c;
      max_score = score;
    }
  }

  if (min_c) {
    min_c->last_sent = t;
  }

  return min_c;
}

void handle_srt_data(sock_t fd) {
  char buf[MTU];
  socklen_t len = sizeof(srt_addr);
  int n = recvfrom(fd, buf, MTU, 0, &srt_addr, &len);
  if (n <= 0) return;

  conn_t *c = select_conn();
  if (c) {
    int32_t sn = get_srt_sn(buf, n);
    int ret = sendto(c->fd, buf, n, 0, &srtla_addr, addr_len);
    if (ret == n) {
      if (sn >= 0) {
        reg_pkt(c, sn);
      }
    } else {
      /* If sending the packet fails, adjust the timestamp to disable the link until a
         reconnection is confirmed. 1 so connection_housekeeping() prints its message */
      c->last_rcvd = 1;
      err("%s (%p): sendto() failed, disabling the connection\n",
          print_addr(&c->src), c);
    }
  }
}


/*

Handling code for packets coming from the receiver

*/
int get_pkt_idx(int idx, int increment) {
  idx = idx + increment;
  if (idx < 0) idx += PKT_LOG_SZ;
  idx %= PKT_LOG_SZ;
  assert(idx >= 0 && idx < PKT_LOG_SZ);
  return idx;
}

void register_nak(int32_t packet) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    int idx = get_pkt_idx(c->pkt_idx, -1);
    for (int i = idx; i != c->pkt_idx; i = get_pkt_idx(i, -1)) {
      if (c->pkt_log[i] == packet) {
        c->pkt_log[i] = -1;
        // It might be better to use exponential decay like this
        //c->window = c->window * 998 / 1000;
        c->window -= WINDOW_DECR;
        c->window = max(c->window, WINDOW_MIN*WINDOW_MULT);
        debug("%s (%p): found NAKed packet %d in the log\n",
              print_addr(&c->src), c, packet);
        return;
      }
    }
  }

  debug("Didn't find NAKed packet %d in our logs\n", packet);
}

void register_srtla_ack(int32_t ack) {
  int found = 0;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    int idx = get_pkt_idx(c->pkt_idx, -1);
    for (int i = idx; i != c->pkt_idx && !found; i = get_pkt_idx(i, -1)) {
      if (c->pkt_log[i] == ack) {
        found = 1;
        if (c->in_flight_pkts > 0) {
          c->in_flight_pkts--;
        }
        c->pkt_log[i] = -1;

        if (c->in_flight_pkts*WINDOW_MULT > c->window) {
          c->window += WINDOW_INCR - 1;
        }

        break;
      }
    }

    if (c->last_rcvd != 0) {
      c->window += 1;
      c->window = min(c->window, WINDOW_MAX*WINDOW_MULT);
    }
  }
}

/*
  TODO after the sequence number overflows, we should probably also mark high
  sn packets as received. However, this shouldn't normally be an issue as SRTLA
  ACKs acknowledge each packet individually. Also, if the SRTLA ACK is lost,
  stale entries will be overwritten soon enough as pkt_log is a circular buffer
*/
void conn_register_srt_ack(conn_t *c, int32_t ack) {
  int count = 0;
  int idx = get_pkt_idx(c->pkt_idx, -1);
  for (int i = idx; i != c->pkt_idx; i = get_pkt_idx(i, -1)) {
    if (c->pkt_log[i] < ack) {
      c->pkt_log[i] = -1;
    } else {
      count++;
    }
  }
  c->in_flight_pkts = count;
}

void register_srt_ack(int32_t ack) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    conn_register_srt_ack(c, ack);
  }
}

void handle_srtla_data(conn_t *c) {
  char buf[MTU];

  int n = recvfrom(c->fd, buf, MTU, 0, NULL, NULL);
  if (n <= 0) return;

  time_t ts;
  get_seconds(&ts);

  uint16_t packet_type = get_srt_type(buf, n);

  /* Handling NGPs separately because we don't want them to update last_rcvd
     Otherwise they could be keeping failed connections marked active */
  if (packet_type == SRTLA_TYPE_REG_NGP) {
    /* Only process NGPs if:
       * we don't have any established connections
       * and we don't already have a pending REG1->REG2 exhange in flight
       * and we don't have any pending REG2->REG3 exchanges in flight
    */
    if (active_connections == 0 && pending_reg2_conn == NULL && ts > pending_reg_timeout) {
      if (send_reg1(c) == 0) {
        pending_reg2_conn = c;
        pending_reg_timeout = ts + REG2_TIMEOUT;
      }
    }
    return;

  } else if (packet_type == SRTLA_TYPE_REG2) {
    if (pending_reg2_conn == c) {
      char *id = &buf[2];
      if (memcmp(id, srtla_id, SRTLA_ID_LEN/2) != 0) {
        err("%s (%p): got a mismatching ID in SRTLA_REG2\n",
           print_addr(&c->src), c);
        return;
      }

      info("%s (%p): connection group registered\n", print_addr(&c->src), c);
      memcpy(srtla_id, id, SRTLA_ID_LEN);

      /* Broadcast REG2 */
      for (conn_t *i = conns; i != NULL; i = i->next) {
        send_reg2(i);
      }

      pending_reg2_conn = NULL;
      pending_reg_timeout = ts + REG3_TIMEOUT;
    }
    return;
  }

  c->last_rcvd = ts;

  switch(packet_type) {
    case SRT_TYPE_ACK: {
      uint32_t last_ack = *((uint32_t *)&buf[16]);
      last_ack = be32toh_(last_ack);
      register_srt_ack(last_ack);
      break;
    }

    case SRT_TYPE_NAK: {
      uint32_t *ids = (uint32_t *)buf;
      for (int i = 4; i < n/4; i++) {
        uint32_t id = be32toh_(ids[i]);
        if (id & (1 << 31)) {
          id = id & 0x7FFFFFFF;
          uint32_t last_id = be32toh_(ids[i+1]);
          for (int32_t lost = id; lost <= last_id; lost++) {
            register_nak(lost);
          }
          i++;
        } else {
          register_nak(id);
        }
      }
      break;
    }

    // srtla packets below, don't send to SRT
    case SRTLA_TYPE_ACK: {
      uint32_t *acks = (uint32_t *)buf;
      for (int i = 1; i < n/4; i++) {
        uint32_t id = be32toh_(acks[i]);
        debug("%s (%p): ack %d\n", print_addr(&c->src), c, id);
        register_srtla_ack(id);
      }
      return;
    }
    case SRTLA_TYPE_KEEPALIVE:
      debug("%s (%p): got a keepalive\n", print_addr(&c->src), c);
      return; // don't send to SRT

    case SRTLA_TYPE_REG3:
      has_connected = 1;
      active_connections++;
      info("%s (%p): connection established\n", print_addr(&c->src), c);
      return;
  } // switch

  sendto(listenfd, buf, n, 0, &srt_addr, addr_len);
}


/*

Connection and socket management

*/
conn_t *conn_find_by_src(struct sockaddr *src) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (memcmp(src, &c->src, sizeof(*src)) == 0) {
      return c;
    }
  }

  return NULL;
}

int setup_conns(char *source_ip_file) {
  FILE *config = fopen(source_ip_file, "r");
  if (config == NULL) {
    perror("Failed to open the source ip list file: ");
    exit_help();
  }

  int count = 0;
  char line[256];
  while (fgets(line, sizeof(line), config)) {
    char *nl;
    if ((nl = strchr(line, '\n'))) {
      *nl = '\0';
    }

    struct sockaddr src;
    memset(&src, 0, sizeof(src));

    int ret = parse_ip((struct sockaddr_in *)&src, line);
    if (ret == 0) {
      conn_t *c = conn_find_by_src(&src);
      if (c == NULL) {
        conn_t *c = calloc(1, sizeof(conn_t));
        assert(c != NULL);

        c->src = src;
        c->fd = BAD_SOCK;
        c->window = WINDOW_DEF * WINDOW_MULT;

        c->next = conns;
        conns = c;

        count++;

        printf("Added connection via %s (%p)\n", print_addr(&c->src), c);
        fflush(stdout);
      } else {
        c->removed = 0;
      }
    }
  }

  fclose(config);

  return count;
}

void update_conns(char *source_ip_file) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    c->removed = 1;
  }

  setup_conns(source_ip_file);

  conn_t **prev = &conns;
  conn_t *next;
  for (conn_t *c = conns; c != NULL; c = next) {
    next = c->next;
    if (c->removed) {
      printf("Removed connection via %s (%p)\n", print_addr(&c->src), c);
      fflush(stdout);

      if (c == pending_reg2_conn) {
        pending_reg2_conn = NULL;
      }

      if (c->fd != BAD_SOCK) {
        remove_active_fd(c->fd);
        close_sock(c->fd);
      }
      *prev = c->next;
      free(c);
    } else {
      prev = &c->next;
    }
  }
}

void schedule_update_conns(int signal) {
  do_update_conns = 1;
}

int open_socket(conn_t *c, int quiet) {
  if (c->fd != BAD_SOCK) {
    remove_active_fd(c->fd);
    close_sock(c->fd);
    c->fd = BAD_SOCK;
  }

  // Set up the socket
  sock_t fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd == BAD_SOCK) {
    err("Failed to open a socket");
    return -1;
  }
  set_nonblock(fd);

  int bufsize = SEND_BUF_SIZE;
  int ret = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, (const char *)&bufsize, sizeof(bufsize));
  if (ret != 0) {
    err("failed to set send buffer size (%d)\n", bufsize);
    goto err;
  }

  // Bind it to the source address
  ret = bind(fd, &c->src, sizeof(c->src));
  if (ret != 0) {
    if (!quiet) {
      err("Failed to bind to the source address %s\n", print_addr(&c->src));
    }
    goto err;
  }

  add_active_fd(fd);
  c->fd = fd;

  return 0;

err:
  close_sock(fd);
  return -1;
}

int open_conns(char *host, char *port) {
  // Check that we can actually open & bind at least one socket
  int opened = 0;
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (open_socket(c, 0) == 0) {
      opened++;
    }
  }
  return opened;
}

/*

Connection housekeeping

*/
void set_srtla_addr(struct addrinfo *addr) {
  memcpy(&srtla_addr, addr->ai_addr, addr->ai_addrlen);
  info("Trying to connect to %s...\n", print_addr(&srtla_addr));
}

void send_keepalive(conn_t *c) {
  debug("%s (%p): sending keepalive\n", print_addr(&c->src), c);
  uint16_t pkt = htobe16_(SRTLA_TYPE_KEEPALIVE);
  // ignoring the result on purpose
  sendto(c->fd, (const char *)&pkt, sizeof(pkt), 0, &srtla_addr, addr_len);
}

#define HOUSEKEEPING_INT 1000 // ms
void connection_housekeeping() {
  static uint64_t all_failed_at = 0;
  /* We use milliseconds here because with a seconds timer we may be
     resending a second REG2 very soon after the first one, depending
     on when the first execution happens within the seconds interval */
  static uint64_t last_ran = 0;
  uint64_t ms;
  assert(get_ms(&ms) == 0);
  if ((last_ran + HOUSEKEEPING_INT) > ms) return;

  time_t time = (time_t)(ms / 1000);

  active_connections = 0;

  if (pending_reg2_conn && time > pending_reg_timeout) {
    pending_reg2_conn = NULL;
  }

  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->fd == BAD_SOCK) {
      open_socket(c, 1);
      continue;
    }

    if (conn_timed_out(c, time)) {
      /* When we first detect the connection having failed,
         we reset its status and print a message */
      if (c->last_rcvd > 0) {
        info("%s (%p): connection failed, attempting to reconnect\n",
             print_addr(&c->src), c);
        c->last_rcvd = 0;
        c->last_sent = 0;
        c->window = WINDOW_MIN * WINDOW_MULT;
        c->in_flight_pkts = 0;
        for (int i = 0; i < PKT_LOG_SZ; i++) {
          c->pkt_log[i] = -1;
        }
      }

      if (pending_reg2_conn == NULL) {
        /* As the connection has timed out on our end, the receiver might have garbage
           collected it. Try to re-establish it rather than send a keepalive */
        send_reg2(c);
      } else if (pending_reg2_conn == c) {
        send_reg1(c);
      }
      continue;
    }

    /* If a connection has received data in the last CONN_TIMEOUT seconds,
       then it's active */
    active_connections++;

    if ((c->last_sent + IDLE_TIME) < time) {
      send_keepalive(c);
    }
  }

  if (active_connections == 0) {
    if (all_failed_at == 0) {
      all_failed_at = ms;
    }

    if (has_connected) {
      err("warning: no available connections\n");
    }

    // Timeout when all connections have failed
    if (ms > (all_failed_at + (GLOBAL_TIMEOUT * 1000))) {
      if (has_connected) {
        err("Failed to re-establish any connections to %s\n",
            print_addr(&srtla_addr));
        exit(EXIT_FAILURE);
      }

      err("Failed to establish any initial connections to %s\n",
          print_addr(&srtla_addr));

      // Walk through the list of resolved addresses
      if (addrs->ai_next) {
        addrs = addrs->ai_next;
        set_srtla_addr(addrs);
        all_failed_at = 0;
      } else {
        exit(EXIT_FAILURE);
      }
    }
  } else {
    all_failed_at = 0;
  }

  last_ran = ms;
}

#define ARG_LISTEN_PORT (argv[1])
#define ARG_SRTLA_HOST  (argv[2])
#define ARG_SRTLA_PORT  (argv[3])
#define ARG_IPS_FILE    (argv[4])
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "-v") == 0) {
    printf(VERSION "\n");
    exit(0);
  }
  if (argc != 5) exit_help();
  setvbuf(stdout, NULL, _IONBF, 0);
#ifdef _WIN32
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { fprintf(stderr, "WSAStartup failed\n"); exit(EXIT_FAILURE); }
#endif

  source_ip_file = ARG_IPS_FILE;
  int conn_count = setup_conns(source_ip_file);
  if (conn_count <= 0) {
    fprintf(stderr, "Failed to parse any IP addresses in %s\n", source_ip_file);
    exit(EXIT_FAILURE);
  }

  struct sockaddr_in listen_addr;

  int port = parse_port(ARG_LISTEN_PORT);
  if (port < 0) exit_help();

  // Read a random connection group id for this session
  random_bytes(srtla_id, SRTLA_ID_LEN);

  FD_ZERO(&active_fds);

  listen_addr.sin_family = AF_INET;
  listen_addr.sin_addr.s_addr = INADDR_ANY;
  listen_addr.sin_port = htons(port);
  listenfd = socket(AF_INET, SOCK_DGRAM, 0);
  if (listenfd == BAD_SOCK) { 
    perror("socket creation failed"); 
    exit(EXIT_FAILURE); 
  }

  int ret = bind(listenfd, (struct sockaddr *)&listen_addr, sizeof(listen_addr));
  if (ret < 0) { 
    perror("bind failed"); 
    exit(EXIT_FAILURE); 
  }
#ifdef _WIN32
  { BOOL f = FALSE; DWORD r = 0;
    WSAIoctl(listenfd, SIO_UDP_CONNRESET, &f, sizeof(f), NULL, 0, &r, NULL, NULL); }
#endif
  add_active_fd(listenfd);

  int connected = open_conns(ARG_SRTLA_HOST, ARG_SRTLA_PORT);
  if (connected < 1) {
    err("Failed to open and bind to any of the IP addresses in %s\n", source_ip_file);
    exit(EXIT_FAILURE);
  }

  // Resolve the address of the receiver
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  ret = getaddrinfo(ARG_SRTLA_HOST, ARG_SRTLA_PORT, &hints, &addrs);
  if (ret != 0) {
    err("Failed to resolve %s: %s\n", ARG_SRTLA_HOST, gai_strerror(ret));
    exit(EXIT_FAILURE);
  }

  set_srtla_addr(addrs);

#ifndef _WIN32
  signal(SIGHUP, schedule_update_conns);
#endif
  static char ips_prev[65536], ips_cur[65536];
  read_whole(source_ip_file, ips_prev, sizeof(ips_prev));
  uint64_t next_ips_check = mono_ms() + 1000;

  int info_int = LOG_PKT_INT;

  while(1) {
    if (mono_ms() >= next_ips_check) {
      next_ips_check = mono_ms() + 1000;
      if (read_whole(source_ip_file, ips_cur, sizeof(ips_cur)) == 0 && strcmp(ips_cur, ips_prev) != 0) {
        memcpy(ips_prev, ips_cur, sizeof(ips_prev));
        do_update_conns = 1;
      }
    }
    if (do_update_conns) {
      update_conns(source_ip_file);
      do_update_conns = 0;
    }

    connection_housekeeping();

    fd_set read_fds = active_fds;
    struct timeval to = {.tv_sec = 0, .tv_usec = 200*1000};
    ret = select(FD_SETSIZE, &read_fds, NULL, NULL, &to);
#ifdef _WIN32
    if (ret < 0) { Sleep(50); continue; }  /* niciun socket activ -> WSAEINVAL */
#endif

    if (ret > 0) {
      if (FD_ISSET(listenfd, &read_fds)) {
        handle_srt_data(listenfd);
      }

      for (conn_t *c = conns; c != NULL; c = c->next) {
        if (c->fd != BAD_SOCK && FD_ISSET(c->fd, &read_fds)) {
          handle_srtla_data(c);
        }
      }
    } // ret > 0

    info_int--;
    if (info_int == 0) {
      for (conn_t *c = conns; c != NULL; c = c->next) {
        debug("%s (%p): in flight: %d, window: %d, last_rcvd %ld\n",
              print_addr(&c->src), c, c->in_flight_pkts, c->window, (long)c->last_rcvd);
      }
      info_int = LOG_PKT_INT;
    }
  } // while(1);
}
'@
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "Ruleaza PowerShell ca Administrator" -ForegroundColor Red; exit 1 }
$TaskName = "nTs-AIR"

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('belacoder.exe','srtla_send.exe') -or $_.CommandLine -like "*$Dir\*air*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-NetFirewallRule -DisplayName "nTs-AIR panel" -ErrorAction SilentlyContinue
  Remove-Item "$env:PUBLIC\Desktop\nTs-AIR.url" -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force "$Dir\bin", "$Dir\src", "$Dir\run" -ErrorAction SilentlyContinue
  Say "Dezinstalat (config pastrat in $Dir\tx.json; MSYS2 ramane in $Msys)"
  exit 0
}

# ---------------------------------------------------------------- MSYS2
$bash = "$Msys\usr\bin\bash.exe"
function MsysRun($cmd) {
  $env:MSYSTEM = "UCRT64"; $env:CHERE_INVOKING = "1"
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  & $bash -lc $cmd 2>&1 | ForEach-Object { "$_" } | Write-Host
  $code = $LASTEXITCODE; $ErrorActionPreference = $old
  if ($code -ne 0) { throw "Comanda MSYS2 a esuat ($code): $cmd" }
}
if (-not (Test-Path $bash)) {
  Say "Instalez MSYS2 in $Msys"
  $sfx = "$env:TEMP\msys2-base.sfx.exe"
  $urls = @("https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe",
            "https://repo.msys2.org/distrib/msys2-x86_64-latest.sfx.exe")
  $ok = $false
  foreach ($u in $urls) { try { Invoke-WebRequest -UseBasicParsing $u -OutFile $sfx; $ok = $true; break } catch { Warn "Descarcare esuata: $u" } }
  if (-not $ok) { throw "Nu pot descarca MSYS2" }
  $parent = Split-Path $Msys -Parent
  & $sfx -y "-o$parent\" | Out-Null
  if (-not (Test-Path $bash)) { throw "Extragerea MSYS2 a esuat" }
  Native $bash @("-lc", "exit") | Out-Null
}
Say "Actualizez MSYS2 (poate dura cateva minute)"
Native $bash @("-lc", "pacman -Syuu --noconfirm") | Out-Null
Native $bash @("-lc", "pacman -Syuu --noconfirm") | Out-Null

Say "Instalez GStreamer, SRT, Python, compilator"
$p = "mingw-w64-ucrt-x86_64"
MsysRun ("pacman -S --needed --noconfirm make $p-gcc $p-pkgconf $p-gstreamer $p-gst-plugins-base " +
         "$p-gst-plugins-good $p-gst-plugins-bad $p-gst-plugins-ugly $p-gst-libav $p-srt $p-python $p-python-psutil")

# ---------------------------------------------------------------- fisiere
Say "Scriu fisierele in $Dir"
New-Item -ItemType Directory -Force -Path "$Dir\bin", "$Dir\src", "$Dir\run" | Out-Null
Write-Sources

Say "Compilez belacoder (encoder cu bitrate adaptiv) si srtla_send (bonding)"
$msDir = "/" + $Dir.Substring(0, 1).ToLower() + ($Dir.Substring(2) -replace '\\', '/')
MsysRun ("cd '$msDir/src' && gcc -O2 -o ../bin/belacoder.exe belacoder_port.c " +
         "`$(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0 srt) -lws2_32 && " +
         "gcc -O2 -o ../bin/srtla_send.exe srtla_send_port.c -lws2_32")

$ucrt = "$Msys\ucrt64\bin"
if (-not (Test-Path "$Dir\tx.json")) {
  Say "Configuratie implicita"
  $enc = "qsv_h264"
  if ((Native "$ucrt\gst-inspect-1.0.exe" @("qsvh264enc")) -ne 0) { Warn "Quick Sync indisponibil (driver Intel?) - folosesc Media Foundation"; $enc = "mf_h264" }
  Put "$Dir\tx.json" ("{`"web_port`": $WebPort, `"rx_host`": `"$RxHost`", `"rx_port`": $RxPort, `"encoder`": `"$enc`"}")
}

# lansator ascuns + task la logare (captura video MF functioneaza in sesiunea utilizatorului)
Put "$Dir\run-air.cmd" "@echo off`r`nset PATH=$ucrt;%PATH%`r`nset GST_DEBUG=1`r`ncd /d `"$Dir`"`r`n:loop`r`n`"$ucrt\python.exe`" `"$Dir\air.py`" >> `"$Dir\air.log`" 2>&1`r`ntimeout /t 3 /nobreak >nul`r`ngoto loop`r`n"
Put "$Dir\run-air.vbs" "CreateObject(`"WScript.Shell`").Run `"`"`"$Dir\run-air.cmd`"`"`", 0, False`r`n"

Say "Pornire automata la logare (Task Scheduler)"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
$user = "$env:USERDOMAIN\$env:USERNAME"
$act = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$Dir\run-air.vbs`""
$trg = New-ScheduledTaskTrigger -AtLogOn -User $user
$prn = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $prn -Settings $set | Out-Null

Remove-NetFirewallRule -DisplayName "nTs-AIR panel" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "nTs-AIR panel" -Direction Inbound -Protocol TCP -LocalPort $WebPort -Action Allow | Out-Null
Put "$env:PUBLIC\Desktop\nTs-AIR.url" "[InternetShortcut]`r`nURL=http://localhost:$WebPort/`r`n"

# opreste instanta veche si porneste
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$Dir\air.py*" -or $_.Name -in @('belacoder.exe','srtla_send.exe') -or ($_.Name -eq 'cmd.exe' -and $_.CommandLine -like '*run-air.cmd*') } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-ScheduledTask -TaskName $TaskName
Start-Sleep 4

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
Write-Host ""
Say "GATA. Panou: http://localhost:$WebPort  (din retea: http://${ip}:$WebPort)  user admin / parola admin"
Write-Host "    Conecteaza modemuri 4G USB / telefoane cu USB tethering / WiFi / LAN - apar automat in panou."
Write-Host "    Log: $Dir\air.log    Pornire automata: la logarea utilizatorului $user"
Start-Process "http://localhost:$WebPort/"
