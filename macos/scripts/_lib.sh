#!/usr/bin/env bash
# Shared helpers for the macOS GoodbyeDPI-Turkey scripts.
#
# This file is intended to be sourced, not executed directly. It provides:
#   - require_root            : re-exec under sudo if not running as root.
#   - require_ciadpi          : ensure macos/bin/ciadpi exists and is executable.
#   - detect_network_service  : print the human-readable network service
#                               (e.g. "Wi-Fi", "Ethernet") of the default route.
#   - save_network_state      : snapshot current SOCKS proxy + DNS settings
#                               for the active service into a state file so
#                               they can be restored later.
#   - apply_proxy / clear_proxy
#   - apply_dns   / clear_dns
#   - cleanup_and_restore     : restore state from the snapshot.
#   - start_ciadpi_foreground : launch ciadpi in the foreground with the
#                               supplied arguments, blocking until it exits.
#
# All operations log clearly and refuse to silently override user state.

set -euo pipefail

# ---- paths -----------------------------------------------------------------

# When sourced, BASH_SOURCE[0] is this file. Resolve repo-relative paths.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${_LIB_DIR}/.." && pwd)"
REPO_DIR="$(cd "${MACOS_DIR}/.." && pwd)"
CIADPI_BIN="${MACOS_DIR}/bin/ciadpi"

STATE_DIR="/var/db/goodbyedpi-turkey"
STATE_FILE="${STATE_DIR}/prev-network-state.env"

LAUNCHD_LABEL="com.cagritaskn.goodbyedpi-turkey"
LAUNCHD_PLIST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
LAUNCHD_TEMPLATE="${MACOS_DIR}/launchd/${LAUNCHD_LABEL}.plist.template"

# ---- split-tunnel / GOST paths ---------------------------------------------
#
# split_tunnel.sh installs a PAC HTTP server plus a GOST HTTP->SOCKS5 bridge
# as launchd daemons on top of the ciadpi service; service_remove.sh tears
# them down again. Shared here so both scripts agree on labels and paths.

ETC_DIR="/usr/local/etc/goodbyedpi-turkey"

# Per-domain DNS resolver files for split-tunnel mode. A file named "<domain>"
# in /etc/resolver makes mDNSResponder (and therefore ciadpi's getaddrinfo)
# resolve that domain — and all its subdomains — via the listed nameservers,
# while every other domain keeps the system/DHCP resolver. This replaces the
# old system-wide Yandex DNS in split-tunnel mode, so non-Discord traffic no
# longer leaks its DNS to Yandex.
RESOLVER_DIR="/etc/resolver"

# Snapshot of each enabled service's DNS, captured when split-tunnel turns on,
# so that 'off' can restore the full-tunnel DNS exactly (Yandex for the default
# method, DHCP for the DNS-off alternatives).
SPLIT_DNS_STATE="${STATE_DIR}/split-dns.env"
PAC_FILE="${ETC_DIR}/proxy.pac"
PAC_PORT="1085"
PAC_URL="http://127.0.0.1:${PAC_PORT}/proxy.pac"
PAC_LABEL="com.cagritaskn.goodbyedpi-turkey-pac"
PAC_PLIST="/Library/LaunchDaemons/${PAC_LABEL}.plist"

GOST_LABEL="com.cagritaskn.goodbyedpi-turkey-gost"
GOST_PLIST="/Library/LaunchDaemons/${GOST_LABEL}.plist"
GOST_PORT="8080"
GOST_LOG="/var/log/goodbyedpi-gost.log"

# A transient, plist-less direct HTTP proxy on GOST_PORT. The uninstall path
# may leave one behind so apps that already inherited the legacy session
# HTTP_PROXY keep working. It is not a launchd plist and must be removed
# whenever the real GOST bridge starts.
DIRECT_BRIDGE_LABEL="com.cagritaskn.goodbyedpi-turkey-direct-bridge"

# Legacy GOST GUI-session env bridge (removed by split_tunnel on/off and
# service_remove). Older versions exported proxy vars to the whole session;
# that made apps die when GOST stopped. Discord's updater now gets the vars
# from the scoped macos/discord-proxy launcher instead.
GOST_ENV_LABEL="com.cagritaskn.goodbyedpi-turkey-gost-env"
GOST_ENV_PLIST="/Library/LaunchAgents/${GOST_ENV_LABEL}.plist"
GOST_ENV_URL="http://127.0.0.1:${GOST_PORT}"
GOST_ENV_NO_PROXY="localhost,127.0.0.1"

# Defaults — overridable by callers BEFORE sourcing or with env vars.
CIADPI_HOST="${CIADPI_HOST:-127.0.0.1}"
CIADPI_PORT="${CIADPI_PORT:-1080}"

# Yandex DNS (matches the Windows scripts' --dns-addr 77.88.8.8 default).
DEFAULT_DNS_V4_PRIMARY="${DEFAULT_DNS_V4_PRIMARY:-77.88.8.8}"
DEFAULT_DNS_V4_SECONDARY="${DEFAULT_DNS_V4_SECONDARY:-77.88.8.1}"

# ---- logging ---------------------------------------------------------------

log()  { printf '\033[1;34m[goodbyedpi-turkey]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[goodbyedpi-turkey]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[goodbyedpi-turkey]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- prerequisite checks ---------------------------------------------------

require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "These scripts only run on macOS. For Windows, use the .cmd files in windows/."
    fi
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log "Yönetici (root) yetkisi gerekiyor — sudo ile yeniden başlatılıyor..."
        # Re-exec the *original* script (passed in as $1) under sudo,
        # preserving its arguments and our tweakable env vars.
        local script="$1"; shift
        exec sudo \
            --preserve-env=CIADPI_HOST,CIADPI_PORT,DEFAULT_DNS_V4_PRIMARY,DEFAULT_DNS_V4_SECONDARY \
            "$script" "$@"
    fi
}

require_ciadpi() {
    if [[ ! -x "$CIADPI_BIN" ]]; then
        err "ciadpi bulunamadı: $CIADPI_BIN"
        err "Önce derleyin:  cd \"$MACOS_DIR\" && ./build.sh"
        exit 1
    fi
}

# ---- network service detection --------------------------------------------

# Print the BSD device name of the default route's interface (e.g. "en0").
default_interface() {
    route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

# Print the human-readable network service name (e.g. "Wi-Fi", "Ethernet")
# associated with the default route. networksetup's commands need this name,
# not the BSD device name. Falls back to "Wi-Fi" with a warning.
detect_network_service() {
    local dev service
    dev="$(default_interface || true)"
    if [[ -z "${dev:-}" ]]; then
        warn "Varsayılan ağ arayüzü tespit edilemedi; 'Wi-Fi' varsayılıyor."
        echo "Wi-Fi"
        return 0
    fi

    # networksetup -listallhardwareports prints groups like:
    #   Hardware Port: Wi-Fi
    #   Device: en0
    #   Ethernet Address: ...
    service="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
        | awk -v dev="$dev" '
            /^Hardware Port:/ { hp = substr($0, index($0,$3)) }
            /^Device:/        { if ($2 == dev) { print hp; exit } }
        ')"

    if [[ -z "${service:-}" ]]; then
        warn "BSD arayüzü '$dev' bir networksetup servisine eşlenemedi; 'Wi-Fi' varsayılıyor."
        service="Wi-Fi"
    fi
    echo "$service"
}

# ---- state save / restore --------------------------------------------------

# True when a SOCKS endpoint is the ciadpi port this tool installs. Such a
# snapshot is a leftover from an earlier GoodbyeDPI install: restoring it
# after removal would point the system at a port that no longer listens and
# kill networking. Callers treat it as "proxy off".
is_self_socks() {
    [[ "${1:-}" == "$CIADPI_HOST" && "${2:-}" == "$CIADPI_PORT" ]]
}

# True when a DNS snapshot is exactly the Yandex pair this tool applies.
is_self_dns() {
    [[ "${1:-}" == "$DEFAULT_DNS_V4_PRIMARY $DEFAULT_DNS_V4_SECONDARY" ]]
}

# Write current SOCKS proxy + DNS state for the given service into STATE_FILE
# so a later cleanup_and_restore can put things back exactly as they were.
# Values that already belong to this tool are normalised to off/empty so a
# reinstall never turns a stale snapshot into a dead proxy after removal.
save_network_state() {
    local service="$1"
    mkdir -p "$STATE_DIR"

    # SOCKS proxy info (printed as "Enabled: Yes/No\nServer: ...\nPort: ...\n...")
    local socks_info
    socks_info="$(/usr/sbin/networksetup -getsocksfirewallproxy "$service" 2>/dev/null || true)"
    local socks_enabled socks_server socks_port
    socks_enabled="$(echo "$socks_info" | awk -F': ' '/^Enabled:/{print $2; exit}')"
    socks_server="$(echo  "$socks_info" | awk -F': ' '/^Server:/{print $2; exit}')"
    socks_port="$(echo    "$socks_info" | awk -F': ' '/^Port:/{print $2; exit}')"

    # DNS servers (one per line, or "There aren't any DNS Servers set ...")
    local dns_list
    dns_list="$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)"
    if [[ "$dns_list" == *"aren't any DNS"* || -z "${dns_list:-}" ]]; then
        dns_list="empty"
    else
        # Compress to space-separated.
        dns_list="$(echo "$dns_list" | tr '\n' ' ' | sed 's/ *$//')"
    fi

    if is_self_socks "$socks_server" "$socks_port" && [[ "${socks_enabled:-No}" == "Yes" ]]; then
        warn "Önceki SOCKS proxy kendi ciadpi portumuzu (${CIADPI_HOST}:${CIADPI_PORT}) gösteriyor; devre dışı olarak kaydediliyor."
        socks_enabled="No"
    fi
    if is_self_dns "$dns_list"; then
        warn "Önceki DNS kendi Yandex ayarımız; kurulum öncesi DHCP olarak kaydediliyor."
        dns_list="empty"
    fi

    {
        echo "# Saved by GoodbyeDPI-Turkey on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "SERVICE=$(printf '%q' "$service")"
        echo "PREV_SOCKS_ENABLED=$(printf '%q' "${socks_enabled:-No}")"
        echo "PREV_SOCKS_SERVER=$(printf '%q'  "${socks_server:-}")"
        echo "PREV_SOCKS_PORT=$(printf '%q'    "${socks_port:-}")"
        echo "PREV_DNS=$(printf '%q'           "${dns_list}")"
    } > "$STATE_FILE"

    log "Önceki ağ ayarları kaydedildi: $STATE_FILE"
}

# ---- proxy / DNS apply -----------------------------------------------------

apply_proxy() {
    local service="$1"
    log "SOCKS proxy ayarlanıyor: ${service} -> ${CIADPI_HOST}:${CIADPI_PORT}"
    /usr/sbin/networksetup -setsocksfirewallproxy      "$service" "$CIADPI_HOST" "$CIADPI_PORT"
    /usr/sbin/networksetup -setsocksfirewallproxystate "$service" on
}

clear_proxy() {
    local service="$1"
    /usr/sbin/networksetup -setsocksfirewallproxystate "$service" off || true
}

apply_dns() {
    local service="$1"
    log "DNS sunucuları ayarlanıyor: ${service} -> ${DEFAULT_DNS_V4_PRIMARY} ${DEFAULT_DNS_V4_SECONDARY}"
    /usr/sbin/networksetup -setdnsservers "$service" \
        "$DEFAULT_DNS_V4_PRIMARY" "$DEFAULT_DNS_V4_SECONDARY"
}

# Restore DNS to "use DHCP-supplied servers".
clear_dns() {
    local service="$1"
    /usr/sbin/networksetup -setdnsservers "$service" "Empty" || true
}

# ---- cleanup trap ----------------------------------------------------------

# Restore state recorded by save_network_state(). Safe to call multiple times.
cleanup_and_restore() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi

    # shellcheck disable=SC1090
    source "$STATE_FILE"
    local svc="${SERVICE:-}"
    if [[ -z "$svc" ]]; then
        rm -f "$STATE_FILE"
        return 0
    fi

    log "Ağ ayarları eski haline döndürülüyor (${svc})..."

    # State files written by older versions may contain this tool's own
    # endpoint/DNS (captured from a previous install). Restoring those would
    # leave the system pointing at a stopped proxy or a DNS we never owned.
    if is_self_socks "${PREV_SOCKS_SERVER:-}" "${PREV_SOCKS_PORT:-}"; then
        PREV_SOCKS_ENABLED="No"
    fi
    if is_self_dns "${PREV_DNS:-}"; then
        PREV_DNS="empty"
    fi

    if [[ "${PREV_SOCKS_ENABLED:-No}" == "Yes" ]] \
       && [[ -n "${PREV_SOCKS_SERVER:-}" ]] \
       && [[ -n "${PREV_SOCKS_PORT:-}" ]]; then
        /usr/sbin/networksetup -setsocksfirewallproxy \
            "$svc" "$PREV_SOCKS_SERVER" "$PREV_SOCKS_PORT" || true
        /usr/sbin/networksetup -setsocksfirewallproxystate "$svc" on || true
    else
        /usr/sbin/networksetup -setsocksfirewallproxystate "$svc" off || true
    fi

    if [[ -z "${PREV_DNS:-}" || "${PREV_DNS}" == "empty" ]]; then
        /usr/sbin/networksetup -setdnsservers "$svc" "Empty" || true
    else
        # shellcheck disable=SC2086
        /usr/sbin/networksetup -setdnsservers "$svc" ${PREV_DNS} || true
    fi

    rm -f "$STATE_FILE"
    log "Geri yükleme tamamlandı."
}

install_cleanup_trap() {
    # EXIT fires for any exit (normal, Ctrl-C, kill, error). Using only EXIT
    # avoids running the restore logic twice when a signal arrives.
    trap cleanup_and_restore EXIT
}

# ---- method definitions ----------------------------------------------------
#
# These are functional macOS equivalents of the Windows GoodbyeDPI-Turkey
# methods. They are NOT bit-for-bit copies — the most powerful Windows trick
# (a fake packet with a low TTL, used by goodbyedpi.exe's -5/-9 presets) is
# not implementable in userspace on macOS, because byedpi's `--fake`/`--ttl`
# options are Windows/Linux only. We compensate with `--split`, `--disorder`,
# `--tlsrec`, `--oob` and HTTP header mixing, which the byedpi maintainers
# explicitly recommend on BSD/macOS.
#
# The mapping below follows the SplitWire-Turkey macOS measurements: most
# ClientHello-splitting methods only pass TLS 1.3, while Discord's updater
# (reqwest/native-tls) uses TLS 1.2. `--split 2 --tlsrec 1+s` ("Split 2") is
# the preset that passes both TLS 1.3 and TLS 1.2, so it is the default.
# The alternatives keep the older Windows-mirroring combinations.
#
# DNS_MODE = "yandex"  -> force the system DNS to Yandex (matches the
#                         Windows scripts that pass --dns-addr 77.88.8.8).
# DNS_MODE = "off"     -> leave DNS untouched (mirrors the Windows scripts
#                         that do NOT pass --dns-addr).
#
# Edit the arrays below if you find a combination that works better for
# your ISP and want to make it the default.

method_args() {
    case "$1" in
        default)
            # Split 2: passes TLS 1.3 and TLS 1.2 (Discord updater).
            echo "--split 2 --tlsrec 1+s"
            ;;
        alt)
            # Mirrors: goodbyedpi.exe --set-ttl 3
            echo "--disorder 3+s --tlsrec 3+s"
            ;;
        alt2)
            # Mirrors: goodbyedpi.exe -5
            echo "--split 1+s --disorder 3+s --mod-http hcsmix,dcsmix"
            ;;
        alt3)
            # Mirrors: goodbyedpi.exe --set-ttl 3 --dns-addr Yandex
            echo "--disorder 1+s --tlsrec 1+s"
            ;;
        alt4)
            # Mirrors: goodbyedpi.exe -5 --dns-addr Yandex
            echo "--split 1+s --disorder 3+s --mod-http hcsmix,dcsmix"
            ;;
        alt5)
            # Mirrors: goodbyedpi.exe -9 --dns-addr Yandex
            echo "--split 1+s --tlsrec 1+s --mod-http hcsmix,dcsmix"
            ;;
        alt6)
            # Mirrors: goodbyedpi.exe -9
            echo "--split 1+s --tlsrec 1+s"
            ;;
        *)
            die "Bilinmeyen yöntem: $1"
            ;;
    esac
}

method_dns_mode() {
    case "$1" in
        default|alt3|alt4|alt5) echo "yandex" ;;
        alt|alt2|alt6)          echo "off"    ;;
        *) die "Bilinmeyen yöntem: $1" ;;
    esac
}

# Convenience: run the full one-shot workflow for the given method name.
# Args: $1 = method name (default | alt | alt2 | alt3 | alt4 | alt5 | alt6)
run_method_oneshot() {
    local method="$1"
    require_macos
    require_root "$0"
    require_ciadpi

    local service
    service="$(detect_network_service)"
    log "Aktif ağ servisi: ${service}"

    save_network_state "$service"
    install_cleanup_trap

    apply_proxy "$service"
    if [[ "$(method_dns_mode "$method")" == "yandex" ]]; then
        apply_dns "$service"
    fi

    # shellcheck disable=SC2046
    start_ciadpi_foreground $(method_args "$method")
}

# ---- launchd service helpers ----------------------------------------------

# Render the plist template, replacing @LABEL@, @CIADPI@ and the
# <!-- ARGS_PLACEHOLDER --> marker line with one <string>…</string> per
# trailing argument.
# Args:
#   $1     = LaunchDaemon label
#   $2     = absolute path to ciadpi
#   $3..$n = ciadpi CLI arguments (each becomes its own <string> element)
render_plist() {
    local label="$1"; shift
    local bin="$1";   shift

    if [[ ! -f "$LAUNCHD_TEMPLATE" ]]; then
        die "launchd şablonu bulunamadı: $LAUNCHD_TEMPLATE"
    fi

    local args=("$@")

    # Read the template line by line; when we hit the marker, emit a
    # <string> element for each arg in its place. Doing it in pure bash
    # avoids awk's "newline in -v" limitation and keeps escaping under
    # our control.
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"<!-- ARGS_PLACEHOLDER -->"* ]]; then
            for a in "${args[@]}"; do
                local escaped="${a//&/&amp;}"
                escaped="${escaped//</&lt;}"
                escaped="${escaped//>/&gt;}"
                printf '        <string>%s</string>\n' "$escaped"
            done
            continue
        fi
        # Substitute the two simple placeholders, line at a time.
        line="${line//@LABEL@/$label}"
        line="${line//@CIADPI@/$bin}"
        printf '%s\n' "$line"
    done < "$LAUNCHD_TEMPLATE"
}

# Install (or replace) the launchd service for the given method, then start
# it. Also applies the system-wide SOCKS proxy + (optionally) Yandex DNS so
# that the service is actually used by applications.
# Args: $1 = method name
run_method_service_install() {
    local method="$1"
    require_macos
    require_root "$0"
    require_ciadpi

    local service
    service="$(detect_network_service)"
    log "Aktif ağ servisi: ${service}"

    # First time install: snapshot existing state once so service_remove can
    # restore it. Do not overwrite an existing snapshot — that would lose the
    # *original* state if the install script is run multiple times.
    if [[ ! -f "$STATE_FILE" ]]; then
        save_network_state "$service"
    else
        log "Önceki ağ ayarı kaydı mevcut, korunuyor: $STATE_FILE"
    fi

    # Stop and unload any prior instance so we can safely replace the plist.
    if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
        log "Eski hizmet durduruluyor..."
        launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
    fi
    rm -f "$LAUNCHD_PLIST"

    log "Yeni launchd plist yazılıyor: $LAUNCHD_PLIST"
    # shellcheck disable=SC2046
    render_plist "$LAUNCHD_LABEL" "$CIADPI_BIN" \
        -i "$CIADPI_HOST" -p "$CIADPI_PORT" $(method_args "$method") \
        > "$LAUNCHD_PLIST"
    chown root:wheel "$LAUNCHD_PLIST"
    chmod 0644 "$LAUNCHD_PLIST"

    log "Hizmet yükleniyor ve başlatılıyor..."
    launchctl bootstrap system "$LAUNCHD_PLIST"
    launchctl enable "system/${LAUNCHD_LABEL}" 2>/dev/null || true
    launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>/dev/null || true

    apply_proxy "$service"
    if [[ "$(method_dns_mode "$method")" == "yandex" ]]; then
        apply_dns "$service"
    fi

    log "Hizmet kuruldu: ${LAUNCHD_LABEL}"
    log "Durum görmek için:  sudo launchctl print system/${LAUNCHD_LABEL}"
    log "Kaldırmak için   :  sudo $(dirname "$0")/service_remove.sh"
}

run_service_remove() {
    require_macos
    require_root "$0"

    # Split-tunnel leftovers first: PAC HTTP server + GOST bridge. These are
    # installed by split_tunnel.sh on top of the ciadpi service.
    #
    # Network settings are cleaned before any daemon is stopped: otherwise
    # macOS keeps pointing at a PAC/SOCKS/GOST port that no longer listens and
    # every new connection fails until the setting is fixed.
    disable_pac_on_services
    if launchctl print "system/${PAC_LABEL}" >/dev/null 2>&1 || [[ -f "$PAC_PLIST" ]]; then
        log "PAC sunucusu kaldırılıyor: ${PAC_LABEL}"
        remove_pac_server
    fi
    # Env vars may outlive the agent plist; leaving them would point new GUI
    # apps at the now-stopped GOST port.
    clear_gost_env_now
    if [[ -f "$GOST_ENV_PLIST" ]] \
       || launchctl print "gui/$(gost_env_uid)/${GOST_ENV_LABEL}" >/dev/null 2>&1; then
        log "GUI env köprüsü kaldırılıyor: ${GOST_ENV_LABEL}"
        remove_gost_env_agent
    fi
    if launchctl print "system/${GOST_LABEL}" >/dev/null 2>&1 || [[ -f "$GOST_PLIST" ]]; then
        log "GOST köprüsü kaldırılıyor: ${GOST_LABEL}"
        remove_gost_service
    fi
    if [[ -d "$RESOLVER_DIR" ]]; then
        log "Per-domain DNS dosyaları kaldırılıyor: $RESOLVER_DIR"
        remove_split_resolvers
    fi
    # If split-tunnel was active, restore the full-tunnel DNS snapshot so no
    # secondary enabled service is left with cleared (Empty) DNS. The
    # cleanup_and_restore below then returns the active service to its
    # pre-install DNS.
    restore_split_dns_state

    # Restore proxy + DNS to whatever was active before installation while
    # ciadpi is still listening, so no new connection is routed to a dead port.
    cleanup_and_restore

    # A snapshot only covers the active service. Clear any remaining SOCKS
    # entry that points at our own ciadpi port (Ethernet, Thunderbolt Bridge,
    # ...) so switching networks after removal cannot hit a dead proxy.
    clear_self_socks_all

    if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
        log "Hizmet durduruluyor: ${LAUNCHD_LABEL}"
        launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
    else
        log "Hizmet zaten yüklü değil: ${LAUNCHD_LABEL}"
    fi

    if [[ -f "$LAUNCHD_PLIST" ]]; then
        log "Plist siliniyor: $LAUNCHD_PLIST"
        rm -f "$LAUNCHD_PLIST"
    fi

    # Keep already-running apps that inherited the old session-wide proxy env
    # alive. New processes are unaffected; `start` removes the bridge.
    start_direct_bridge_if_needed

    log "GoodbyeDPI-Turkey kaldırıldı."
}

# ---- split-tunnel / GOST helpers -------------------------------------------

# Print every enabled network service name (Wi-Fi, Ethernet, ...).
# *-prefixed (disabled) services are skipped — networksetup refuses to touch
# them, and a proxy set on a disabled service vanishes when it is enabled.
network_services() {
    /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*' || true
}

# Turn SOCKS off on every service whose proxy points at our own ciadpi port.
# Other proxy configurations are left untouched.
clear_self_socks_all() {
    local svc info server port
    while read -r svc; do
        info="$(/usr/sbin/networksetup -getsocksfirewallproxy "$svc" 2>/dev/null || true)"
        server="$(echo "$info" | awk -F': ' '/^Server:/{print $2; exit}')"
        port="$(echo "$info" | awk -F': ' '/^Port:/{print $2; exit}')"
        if is_self_socks "$server" "$port"; then
            /usr/sbin/networksetup -setsocksfirewallproxystate "$svc" off || true
        fi
    done < <(network_services)
}

# Print the split-tunnel domain list (non-comment, non-blank lines only).
split_domains() {
    local f="$ETC_DIR/split-tunnel-domains.txt"
    [[ -f "$f" ]] || f="$MACOS_DIR/split-tunnel-domains.txt"
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true
}

# Write /etc/resolver/<domain> files so only the split-tunnel domains resolve
# via the clean DNS (Yandex) while the rest of the system keeps its normal
# resolver. mDNSResponder picks these up automatically; ciadpi's getaddrinfo()
# goes through mDNSResponder, so its own lookups of Discord domains also land
# on Yandex — no need for a system-wide Yandex DNS anymore.
install_split_resolvers() {
    mkdir -p "$RESOLVER_DIR"
    local d
    while read -r d; do
        [[ -z "$d" ]] && continue
        printf 'nameserver %s\nnameserver %s\n' \
            "$DEFAULT_DNS_V4_PRIMARY" "$DEFAULT_DNS_V4_SECONDARY" \
            > "$RESOLVER_DIR/$d"
        log "Per-domain DNS: $d -> $DEFAULT_DNS_V4_PRIMARY"
    done < <(split_domains)
    /usr/bin/dscacheutil -flushcache 2>/dev/null || true
}

remove_split_resolvers() {
    local d
    while read -r d; do
        [[ -z "$d" ]] && continue
        rm -f "$RESOLVER_DIR/$d"
    done < <(split_domains)
    rmdir "$RESOLVER_DIR" 2>/dev/null || true
    /usr/bin/dscacheutil -flushcache 2>/dev/null || true
}

# Snapshot the current DNS of every enabled service so split-tunnel 'off' can
# restore the full-tunnel DNS exactly. Format: "<service>|<space-separated dns>".
save_split_dns_state() {
    mkdir -p "$STATE_DIR"
    : > "$SPLIT_DNS_STATE"
    local svc dns
    while read -r svc; do
        dns="$(/usr/sbin/networksetup -getdnsservers "$svc" 2>/dev/null || true)"
        if [[ "$dns" == *"aren't any DNS"* || -z "$dns" ]]; then
            dns="empty"
        else
            dns="$(echo "$dns" | tr '\n' ' ' | sed 's/ *$//')"
        fi
        printf '%s|%s\n' "$svc" "$dns" >> "$SPLIT_DNS_STATE"
    done < <(network_services)
}

# Restore the DNS snapshot captured by save_split_dns_state(), then drop it.
restore_split_dns_state() {
    [[ -f "$SPLIT_DNS_STATE" ]] || return 0
    local line svc dns
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        svc="${line%%|*}"
        dns="${line#*|}"
        if [[ "$dns" == "empty" ]]; then
            /usr/sbin/networksetup -setdnsservers "$svc" "Empty" || true
        else
            # shellcheck disable=SC2086
            /usr/sbin/networksetup -setdnsservers "$svc" $dns || true
        fi
    done < "$SPLIT_DNS_STATE"
    rm -f "$SPLIT_DNS_STATE"
}

# Drop the system-wide DNS (back to DHCP) on every enabled service. Used when
# entering split-tunnel mode so only the listed domains keep Yandex via
# /etc/resolver and everything else resolves through the ISP as normal.
clear_dns_all() {
    local svc
    while read -r svc; do
        /usr/sbin/networksetup -setdnsservers "$svc" "Empty" || true
    done < <(network_services)
}

# Locate the GOST binary. Homebrew installs to /opt/homebrew (Apple Silicon)
# or /usr/local (Intel); launchd daemons run with a minimal PATH, so the plist
# needs an absolute path.
gost_bin() {
    local p
    for p in "/opt/homebrew/bin/gost" "/usr/local/bin/gost"; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    if p="$(command -v gost 2>/dev/null || true)" && [[ -n "$p" && -x "$p" ]]; then
        echo "$p"
        return 0
    fi
    return 1
}

require_gost() {
    if ! gost_bin >/dev/null 2>&1; then
        err "GOST bulunamadı. Discord güncelleyicisi SOCKS5 kullanamadığı için"
        err "HTTP->SOCKS5 köprüsü gereklidir:  brew install gost"
        exit 1
    fi
}

# Wait until a local TCP port accepts connections.
# Args: $1 = port, $2 = tries (each ~0.25s), default 20.
wait_port() {
    local port="$1" tries="${2:-20}" n
    for n in $(seq 1 "$tries"); do
        if /usr/bin/nc -z -G 1 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

# Serve $PAC_FILE over HTTP on $PAC_PORT. Chromium (Discord, Chrome) refuses
# file:// PAC URLs, so python3's http.server runs as a launchd daemon.
install_pac_server() {
    mkdir -p "$ETC_DIR"
    cat >"$PAC_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PAC_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>-m</string>
        <string>http.server</string>
        <string>$PAC_PORT</string>
        <string>--bind</string>
        <string>127.0.0.1</string>
        <string>--directory</string>
        <string>$ETC_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
    chmod 644 "$PAC_PLIST"
    launchctl bootout "system/$PAC_LABEL" 2>/dev/null || true
    launchctl bootstrap system "$PAC_PLIST"
    launchctl enable "system/$PAC_LABEL" 2>/dev/null || true
}

remove_pac_server() {
    launchctl bootout "system/$PAC_LABEL" 2>/dev/null || true
    rm -f "$PAC_PLIST"
}

# Turn the auto-proxy (PAC) setting off on every enabled service. SOCKS proxy
# state is NOT touched here — the callers manage that separately.
disable_pac_on_services() {
    local svc
    while read -r svc; do
        /usr/sbin/networksetup -setautoproxystate "$svc" off || true
    done < <(network_services)
}

# (Re)install the GOST HTTP->SOCKS5 bridge as a launchd daemon. Discord's
# updater cannot use a SOCKS5 proxy, so split-tunnel PAC routes matched
# domains via GOST first (see split_tunnel.sh::write_pac).
install_gost_service() {
    require_gost
    local bin
    bin="$(gost_bin)"

    cat >"$GOST_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$GOST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin</string>
        <string>-L</string>
        <string>http://127.0.0.1:$GOST_PORT</string>
        <string>-F</string>
        <string>socks5://127.0.0.1:$CIADPI_PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$GOST_LOG</string>
    <key>StandardErrorPath</key>
    <string>$GOST_LOG</string>
</dict>
</plist>
PLIST
    chmod 644 "$GOST_PLIST"

    # A plist-less direct bridge from an uninstall can hold GOST_PORT while
    # this launchd job exists but never gets a pid. Remove it first.
    launchctl remove "$DIRECT_BRIDGE_LABEL" 2>/dev/null || true
    pkill -f "gost -L http://127.0.0.1:${GOST_PORT}$" 2>/dev/null || true

    launchctl bootout "system/$GOST_LABEL" 2>/dev/null || true
    launchctl bootstrap system "$GOST_PLIST"
    launchctl enable "system/$GOST_LABEL" 2>/dev/null || true
    launchctl kickstart -k "system/$GOST_LABEL" 2>/dev/null || true

    # Do not trust the port alone: an unrelated process holding :8080 makes
    # bootstrap succeed with no GOST pid, and every proxied request then goes
    # to the wrong place. Fail loudly instead.
    local pid="" _
    for _ in $(seq 1 25); do
        pid="$(launchctl print "system/$GOST_LABEL" 2>/dev/null \
            | awk '/^[[:space:]]*pid = /{print $2; exit}')"
        [[ -n "$pid" ]] && break
        sleep 0.2
    done
    if [[ -z "$pid" ]]; then
        die "GOST launchd süreci başlamadı; :${GOST_PORT} başka bir süreç tarafından kullanılıyor olabilir."
    fi
}

remove_gost_service() {
    launchctl bootout "system/$GOST_LABEL" 2>/dev/null || true
    launchctl remove "$DIRECT_BRIDGE_LABEL" 2>/dev/null || true
    pkill -f "gost -L http://127.0.0.1:${GOST_PORT}$" 2>/dev/null || true
    rm -f "$GOST_PLIST"
}

# ---- GOST proxy env (legacy cleanup only) ----------------------------------
#
# Older versions wrote HTTP_PROXY/HTTPS_PROXY into the whole GUI session
# (launchctl setenv + a login LaunchAgent) so Discord's updater would use the
# GOST bridge. That poisoned every app launched afterwards: when GOST stopped,
# those apps kept pointing at a dead port and lost connectivity. The updater
# now gets these vars from the scoped `macos/discord-proxy` launcher instead.
# These helpers remain to remove the legacy session vars and LaunchAgent.

# Print "<key> <value>" pairs the Discord updater needs.
gost_env_pairs() {
    printf 'HTTP_PROXY %s\n' "$GOST_ENV_URL"
    printf 'HTTPS_PROXY %s\n' "$GOST_ENV_URL"
    printf 'ALL_PROXY %s\n' "$GOST_ENV_URL"
    printf 'NO_PROXY %s\n' "$GOST_ENV_NO_PROXY"
}

# Target the GUI session that invoked sudo. Falls back to the console user so
# root shells without SUDO_UID (launchd, `osascript ... with administrator
# privileges`, `sudo -i`) still update the logged-in session's environment.
gost_env_uid() {
    if [[ -n "${SUDO_UID:-}" ]]; then
        echo "$SUDO_UID"
        return 0
    fi
    local uid
    uid="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || true)"
    echo "${uid:-$(id -u)}"
}

clear_gost_env_now() {
    local uid k v
    uid="$(gost_env_uid)"
    while read -r k v; do
        launchctl asuser "$uid" launchctl unsetenv "$k" 2>/dev/null || true
    done < <(gost_env_pairs)
}

remove_gost_env_agent() {
    local uid
    uid="$(gost_env_uid)"
    if [[ -n "$uid" && "$uid" != "0" ]]; then
        launchctl bootout "gui/${uid}/${GOST_ENV_LABEL}" 2>/dev/null || true
    fi
    rm -f "$GOST_ENV_PLIST"
}

# True when any running process still carries the legacy session-wide proxy
# env. `launchctl unsetenv` only affects future processes; already-running
# apps keep the variable and would lose connectivity when GOST stops.
# macOS exposes another process's env through `ps -E` (plain `ps eww` hides it).
legacy_proxy_env_in_use() {
    /bin/ps -E -ax 2>/dev/null | grep -F "HTTP_PROXY=$GOST_ENV_URL" >/dev/null 2>&1
}

# If legacy-env processes are still alive, leave a transient, plist-less
# direct HTTP proxy on GOST_PORT so they keep working after removal. It does
# no DPI bypass and is removed by the next `start` or a reboot.
start_direct_bridge_if_needed() {
    legacy_proxy_env_in_use || return 0

    local bin
    if ! bin="$(gost_bin)"; then
        warn "Eski oturum proxy env'i hâlâ kullanımda ama gost bulunamadı; bu uygulamalar bağlantı kuramayabilir."
        return 0
    fi

    log "Eski proxy env'i taşıyan uygulamalar var; geçici doğrudan köprü :${GOST_PORT} başlatılıyor."
    launchctl remove "$DIRECT_BRIDGE_LABEL" 2>/dev/null || true
    : >"/var/log/goodbyedpi-direct-bridge.log"
    if ! launchctl submit -l "$DIRECT_BRIDGE_LABEL" \
        -o "/var/log/goodbyedpi-direct-bridge.log" \
        -e "/var/log/goodbyedpi-direct-bridge.log" \
        -- "$bin" -L "http://127.0.0.1:${GOST_PORT}"; then
        warn "Geçici köprü başlatılamadı."
        return 0
    fi
    if wait_port "$GOST_PORT" 20; then
        log "Geçici köprü hazır (DPI bypass yok); yeni oturumda gerekmez, start veya yeniden başlatma kaldırır."
    else
        warn "Geçici köprü :${GOST_PORT} dinlemiyor."
    fi
}

# ---- ciadpi runner ---------------------------------------------------------

# Run ciadpi in the foreground with the supplied args.
# The caller is expected to have arranged proxy / DNS / cleanup beforehand.
# We deliberately do NOT exec — we run ciadpi as a child and `wait`, so that
# the EXIT/INT/TERM trap (cleanup_and_restore) still fires when ciadpi exits
# or the user hits Ctrl-C.
start_ciadpi_foreground() {
    log "ciadpi başlatılıyor: $CIADPI_BIN -i $CIADPI_HOST -p $CIADPI_PORT $*"
    log "Ctrl-C veya pencereyi kapatmak GoodbyeDPI-Turkey'i durdurur."
    # ciadpi needs ~2 FDs per proxied connection (client + upstream) and caps
    # out at 512 connections by default. macOS shells ship with a 256 soft
    # limit, which used to end in "accept: Too many open files" and broken
    # tunnels. Raise the soft limit for the child only.
    (
        ulimit -n 10240 2>/dev/null || true
        exec "$CIADPI_BIN" -i "$CIADPI_HOST" -p "$CIADPI_PORT" "$@"
    ) &
    local pid=$!
    # Forward SIGINT/SIGTERM to the child so it shuts down gracefully.
    trap 'kill -TERM '"$pid"' 2>/dev/null || true' INT TERM
    wait "$pid"
}
