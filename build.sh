#!/usr/bin/env bash
# Asambleaza nts-air.sh (scriptul all-in-one) din src/
set -e
cd "$(dirname "$0")"
emb(){ # emb <dest> <file> <marker>
  echo "cat > $1 <<'$3'"; cat "$2"; echo "$3"; }
{
  cat src/installer.sh
  echo 'write_app(){'
  emb '$BASE/air.py'   src/tx/air.py   NTS_PY_EOF
  emb '$BASE/air.html' src/tx/air.html NTS_HTML_EOF
  echo 'chmod 755 $BASE/air.py'; echo '}'; echo
  echo 'write_rx(){'
  emb '$BASE/rx.py'    src/rx/rx.py    NTS_RXPY_EOF
  emb '$BASE/rx.html'  src/rx/rx.html  NTS_RXHTML_EOF
  echo 'chmod 755 $BASE/rx.py'; echo '}'; echo
  cat <<'X'
case "$1" in
  tx) install_tx ;;
  rx) install_rx ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "Folosire: sudo bash $0 tx|rx|status|uninstall"; exit 1 ;;
esac
X
} > nts-air.sh
chmod +x nts-air.sh
bash -n nts-air.sh && echo "nts-air.sh OK ($(wc -l < nts-air.sh) linii)"

# ---- Windows: nts-air-win.ps1 (UTF-8 cu BOM, pentru PowerShell 5.1)
embps(){ # embps <nume> <fisier>
  echo "  Put \"\$Dir\\$1\" @'"; cat "$2"; echo "'@"; }
{
  printf '\xef\xbb\xbf'
  sed -n '1,/^#@@SOURCES@@$/p' win/installer.ps1 | sed '$d'
  echo 'function Write-Sources {'
  embps 'air.py'                 src/tx/air.py
  embps 'air.html'               src/tx/air.html
  embps 'src\belacoder_port.c'   win/src/belacoder_port.c
  embps 'src\srtla_send_port.c'  win/src/srtla_send_port.c
  echo '}'
  sed -n '/^#@@SOURCES@@$/,$p' win/installer.ps1 | sed '1d'
} > nts-air-win.ps1
echo "nts-air-win.ps1 OK ($(wc -l < nts-air-win.ps1) linii)"
