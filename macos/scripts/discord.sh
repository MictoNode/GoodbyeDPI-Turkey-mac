#!/usr/bin/env bash
set -euo pipefail

GOST="/opt/homebrew/bin/gost"
DISCORD="/Applications/Discord.app/Contents/MacOS/Discord"

if [[ ! -x "$GOST" ]]; then
    echo "gost bulunamadı: $GOST"
    exit 1
fi

if [[ ! -x "$DISCORD" ]]; then
    echo "Discord bulunamadı: $DISCORD"
    exit 1
fi

if ! pgrep -f 'ciadpi.*127.0.0.1.*1080' >/dev/null 2>&1; then
    echo "ciadpi çalışmıyor. Önce GoodbyeDPI yöntemini başlatın."
    exit 1
fi

if ! pgrep -f 'gost.*127.0.0.1:8080.*127.0.0.1:1080' >/dev/null 2>&1; then
    echo "GOST başlatılıyor..."
    "$GOST" -L http://127.0.0.1:8080 -F socks5://127.0.0.1:1080 >/tmp/goodbyedpi-gost.log 2>&1 &
    sleep 1
fi

export HTTP_PROXY="http://127.0.0.1:8080"
export HTTPS_PROXY="http://127.0.0.1:8080"
export ALL_PROXY="http://127.0.0.1:8080"
export NO_PROXY="localhost,127.0.0.1"

exec "$DISCORD"
