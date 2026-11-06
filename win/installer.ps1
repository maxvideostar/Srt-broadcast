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
#@@SOURCES@@

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
