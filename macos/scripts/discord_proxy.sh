#!/usr/bin/env bash
set -euo pipefail

GOST="/opt/homebrew/bin/gost"
CIADPI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/ciadpi"

if [[ ! -x "$GOST" ]]; then
    echo "gost bulunamadı: $GOST"
    exit 1
fi

if [[ ! -x "$CIADPI" ]]; then
    echo "ciadpi bulunamadı: $CIADPI"
    exit 1
fi

if ! pgrep -f "$CIADPI.*127.0.0.1.*1080" >/dev/null 2>&1; then
    echo "ciadpi çalışmıyor. Önce GoodbyeDPI yöntemini başlatın."
    exit 1
fi

if pgrep -f "$GOST.*127.0.0.1:8080.*127.0.0.1:1080" >/dev/null 2>&1; then
    echo "GOST zaten çalışıyor."
    exit 0
fi

exec "$GOST" -L http://127.0.0.1:8080 -F socks5://127.0.0.1:1080
