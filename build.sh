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
