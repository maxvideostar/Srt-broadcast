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
