#!/usr/bin/env python3
# nTs-AIR transmitter - panel web + control belacoder/srtla_send + source routing
import json, os, re, signal, subprocess, threading, time, base64, glob, collections, shlex
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BASE = os.environ.get("NTS_AIR_BASE", "/opt/nts-air")
CONF = os.environ.get("NTS_AIR_CONF", "/etc/nts-air/tx.json")
RUN = os.environ.get("NTS_AIR_RUN", "/run/nts-air")
BELACODER = BASE + "/bin/belacoder"
SRTLA_SEND = BASE + "/bin/srtla_send"
LOCAL_SRT_PORT = 9000

DEFAULT = {
    "web_port": 8080, "web_user": "admin", "web_pass": "admin",
    "rx_host": "netstreaming.eu", "rx_port": 5000, "streamid": "",
    "latency": 2000, "min_kbps": 500, "max_kbps": 7000,
    "video_src": "test", "video_dev": "/dev/video0",
    "width": 1920, "height": 1080, "fps": 25, "gop_sec": 2,
    "encoder": "x264", "audio_src": "test", "audio_dev": "hw:1,0",
    "audio_kbps": 128, "av_delay": 0,
    "auto_links": True, "disabled_links": [], "autostart": False,
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

def sh(cmd):
    try: return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=5).stdout
    except Exception: return ""

# ---------------------------------------------------------------- pipeline
ENCODERS = {
    "x264":      ("x264 (CPU)", "x264enc name=venc_kbps speed-preset=superfast tune=zerolatency bitrate={kb} key-int-max={gop} ! video/x-h264,profile=high", "h264parse"),
    "va_h264":   ("Intel H.264 (VA)", "vah264enc name=venc_kbps rate-control=cbr bitrate={kb} key-int-max={gop} b-frames=0 target-usage=4", "h264parse"),
    "va_h265":   ("Intel HEVC (VA)", "vah265enc name=venc_kbps rate-control=cbr bitrate={kb} key-int-max={gop} b-frames=0 target-usage=4", "h265parse"),
    "vaapi_h264":("Intel H.264 (VAAPI vechi)", "vaapih264enc name=venc_kbps rate-control=cbr bitrate={kb} keyframe-period={gop}", "h264parse"),
    "vaapi_h265":("Intel HEVC (VAAPI vechi)", "vaapih265enc name=venc_kbps rate-control=cbr bitrate={kb} keyframe-period={gop}", "h265parse"),
}

def build_pipeline(c):
    w, h, fps = int(c["width"]), int(c["height"]), int(c["fps"])
    gop = max(1, int(c["gop_sec"]) * fps)
    vs = c["video_src"]; dev = c["video_dev"]
    if vs == "mjpeg":
        v = f"v4l2src device={dev} do-timestamp=true ! image/jpeg,width={w},height={h},framerate={fps}/1 ! jpegparse ! jpegdec"
    elif vs == "yuy2":
        v = f"v4l2src device={dev} do-timestamp=true ! video/x-raw,format=YUY2,width={w},height={h},framerate={fps}/1"
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
         f"video/x-raw,width=384,height=216 ! jpegenc quality=60 ! multifilesink location={RUN}/preview.jpg "
         f"t. ! queue ! {enc} ! {parse} config-interval=-1 ! "
         f"queue max-size-time=10000000000 max-size-buffers=1000 max-size-bytes=41943040 ! mux. ")
    a = c["audio_src"]
    if a != "none":
        if a == "alsa":
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

class Router:
    def __init__(self): self.applied = {}
    def apply(self, links):
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
        for t in list(self.applied): self.flush(t)
        self.applied = {}

def read_netdev():
    d = {}
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
                self.bond.send_signal(signal.SIGHUP); self.L("Legaturi actualizate: " + ips.strip().replace("\n", ", "))

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
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                             start_new_session=True)
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
            if self.enc and self.enc.poll() is None: self.enc.send_signal(signal.SIGHUP)

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

def devices():
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
    return {"video": v, "audio": a, "gpu": gpu,
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
