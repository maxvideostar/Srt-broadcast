# nTs-AIR — transmițător bonding SRT (stil AIR220) + receiver cu panou

Transmisie live din teren pe mai multe conexiuni simultan (modemuri 4G/5G USB, telefoane în USB tethering, WiFi, Ethernet), cu bitrate adaptiv, către un server propriu.

```
[HDMI] -> mini PC (nTs-AIR TX) ==4G/4G/WiFi/LAN==> server (nTs-AIR RX) -> HTTP-TS / UDP / multicast / SRT / RTMP
           belacoder + srtla_send                      srtla_rec + srt-live-transmit + panou
```

## Instalare

Un singur script, `nts-air.sh`:

```bash
# Transmițător (mini PC Ubuntu 22.04/24.04, ideal cu Intel iGPU)
sudo RX_HOST=netstreaming.eu bash nts-air.sh tx      # panou: http://IP:8080

# Receiver (server)
sudo bash nts-air.sh rx                               # panou: http://IP:8090

sudo bash nts-air.sh status
sudo bash nts-air.sh uninstall
```

Utilizator/parolă implicite: `admin` / `admin`. Schimbă parola din panou.

### Windows (transmițător)

PowerShell **ca Administrator**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/maxvideostar/Srt-broadcast/main/nts-air-win.ps1).TrimStart([char]0xFEFF))) -RxHost netstreaming.eu
```

sau descarci `nts-air-win.ps1` și rulezi `.\nts-air-win.ps1 -RxHost netstreaming.eu`.

Scriptul instalează MSYS2 (GStreamer + SRT) în `C:\msys64`, compilează encoderul și bonding-ul în `C:\nts-air`, pornește panoul la `http://localhost:8080` și îl setează să pornească la logare. Encoderul implicit e Intel Quick Sync; dacă driverul Intel lipsește, folosește Media Foundation. Captura HDMI merge prin Media Foundation, audio prin WASAPI. Pe Windows nu e nevoie de rutare pe sursă, pentru că sistemul trimite pachetele pe interfața care deține IP-ul.
Dezinstalare: `.\nts-air-win.ps1 -Uninstall`.

## Transmițător (`tx`)

- Panou care imită aparatul: ecran cu preview, bitrate mare, timer de live, iconițe pentru legături. Butonul central pornește/oprește transmisia, iar ◀ ▶ schimbă bitrate-ul maxim în timpul transmisiei.
- Surse: captură HDMI USB (MJPEG), YUY2/CamLink, auto-detect, test pattern sau **link de rețea** (RTSP de la camere IP, SRT, RTMP, UDP/multicast, HTTP/HLS). Audio: din link, ALSA, PulseAudio sau ton de test.
- Encodare: Intel VA H.264/HEVC, VAAPI (pentru GStreamer mai vechi) sau x264. Bitrate-ul se adaptează la rețea între min și max (belacoder).
- Bonding: SRTLA. Interfețele cu IP sunt detectate automat. Rutarea pe sursă (o tabelă pentru fiecare legătură) se face automat, iar orice legătură se poate dezactiva din panou.
- Dacă encoderul sau o legătură cade, pornesc automat din nou. Transmisia poate porni singură la boot.

### Blackmagic DeckLink

Pe emițător, DeckLink e sursă video și audio: SDI sau HDMI, cu mod `auto` sau fix, deinterlace automat. Pe receptor e ieșire SDI/HDMI.
Driverul Desktop Video nu se poate descărca automat, pentru că Blackmagic cere un formular. Îl descarci de pe [blackmagicdesign.com/support](https://www.blackmagicdesign.com/support/family/capture-and-playback), pui arhiva `.tar.gz` lângă `nts-air.sh` și rulezi `sudo bash nts-air.sh decklink`. Dacă placa e detectată în `lspci`, instalarea tx/rx încearcă singură acest pas.

## Receiver (`rx`)

Panou în stil StreamHub, cu mai multe canale. Fiecare canal are propriul port UDP SRTLA, deci poți avea câte un transmițător pe fiecare canal.

- Afișează starea (ON AIR / AȘTEAPTĂ), uptime, bitrate cu grafic pe 2 minute, preview la fiecare 10 secunde, codec, rezoluție și audio.
- **Legăturile bonded** apar separat: IP:port, Mbps, procentul din total și operatorul (Orange / Vodafone / Digi / Telekom, după reverse DNS).
- Statistici SRT: RTT, pachete pierdute și aruncate (drop) în ultimele 10 secunde.
- Ieșiri: le alegi din formularul canalului (tip din listă + câmpuri), sau ca text în secțiunea „Avansat”.
  - **Port Astra global** (butonul „Port Astra”, implicit 8000): fiecare canal e automat la `http://IP:8000/NUME`, ca la Astra. 0 = oprit.
  - HTTP-TS mereu activ: `http://server:8090/live/NUME.ts` sau `http://server:8090/NUME`, cu lista clienților conectați.
  - `udp://IP:port` pentru unicast sau multicast (`?ttl=4&localaddr=IP`).
  - `srt://...` ca listener sau caller.
  - `rtmp://...` (doar H.264).
  - `http://0.0.0.0:8000/cale`: HTTP-TS pe un port separat, ca output-ul `http` din Astra. Mai multe canale pot folosi același port, cu căi diferite.
  - `rtp://239.x.x.x:port?ttl=4`: multicast RTP (MP2T, PT 33), pe lângă multicast UDP simplu.
  - `hdmi://?connector=HDMI-A-1&audio=alsa/hdmi:CARD=PCH,DEV=0`: decodare pe ecranul serverului (mpv pe DRM/KMS, accelerare hardware), ca un decoder StreamHub. Merge doar pe un server fizic fără desktop pornit. Ecranele conectate apar în fereastra de editare a canalului.
  - `decklink://?device=0&mode=1080i50`: ieșire SDI/HDMI pe o placă Blackmagic DeckLink (moduri 1080i50, 1080p25, 1080p50, 720p50, pal; `&audio=0` fără sunet).
  - În fereastra canalului ai butoane gata făcute pentru fiecare tip de ieșire.
- Configurația se păstrează în `/etc/nts-air/rx.json`.

Porturi: UDP 5000+ pentru canale și TCP 8090 pentru panou. Le deschizi și în firewall-ul providerului.

## Dezvoltare

Sursele sunt în `src/` și `win/`. `./build.sh` le asamblează în `nts-air.sh` și `nts-air-win.ps1`.

```
src/installer.sh            instalator Linux (tx / rx / status / uninstall)
src/tx/air.py, air.html     panou + control transmițător (Linux și Windows)
src/rx/rx.py, rx.html       panou + control receiver
win/installer.ps1           instalator Windows
win/src/belacoder_port.c    belacoder portat (Windows + Linux), GPLv3
win/src/srtla_send_port.c   srtla_send portat (Winsock + Linux), AGPLv3
```

Porturile din `win/src/` sunt derivate din proiectele BELABOX și își păstrează licențele (GPLv3 / AGPLv3). Pe Windows nu există `SIGHUP`, așa că fișierele de bitrate și de IP-uri se verifică la fiecare secundă. Pe Linux, `SIGHUP` funcționează în continuare.

Se bazează pe [belacoder](https://github.com/BELABOX/belacoder), [srtla](https://github.com/BELABOX/srtla) și [srt (fork BELABOX)](https://github.com/BELABOX/srt), care se compilează la instalare.
