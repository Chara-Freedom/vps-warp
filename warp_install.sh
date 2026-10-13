#!/bin/bash

# ==============================================================================
#  VPS-WARP PRO (Xray Edition) - Ultimate Production Installer (v5.0)
# ==============================================================================
#
#  Deliberately NOT using `set -euo pipefail`: the flow depends on many probes
#  failing quietly (`systemctl disable ... || true`, `command -v`, optional
#  cleanups). Errors that matter are handled explicitly via fail().
# ==============================================================================

APP_DIR="/opt/vps-warp"
SCRIPT_LANG="en"

# Bump on every release. Used by `vps-warp update` for version comparison.
SCRIPT_VERSION="5.0"

# Persistent state dir — NOT wiped by the cleanup step. Holds installed version,
# the wgcf working directory and the watchdog's backoff state.
STATE_DIR="/etc/vps-warp"
VERSION_FILE="${STATE_DIR}/version"
LICENSE_FILE="${STATE_DIR}/license"
WGCF_DIR="${STATE_DIR}/wgcf"
WATCHDOG_STATE="${STATE_DIR}/watchdog.state"
# Marker: the egress country check is off (installer flag --no-egress-check).
# Read at run time by the watchdog and the CLI, so creating or removing it by
# hand takes effect without a reinstall.
EGRESS_OFF_FILE="${STATE_DIR}/no-egress-check"
# Number of WARP accounts (installer flag --accounts N). Kept here because
# `vps-warp update` re-runs this script with no arguments.
ACCOUNTS_FILE="${STATE_DIR}/accounts"
MAX_ACCOUNTS=10

# Routing knobs. WARP_FWMARK must match what Xray marks its packets with
# (sockopt.mark), otherwise the ip rule below never matches and traffic
# silently leaves the box unencapsulated.
WARP_IFACE="warp"
WARP_FWMARK=255
WARP_TABLE=51820
WARP_MTU=1280
WARP_MSS=$((WARP_MTU - 40))

# Several accounts (--accounts N). Cloudflare limits how many new connections
# one WARP device accepts: past that it stops answering SYNs, and a second
# account on the same server, endpoint and egress address is answered at once.
# So account k gets its own interface (warp, warp2, ...), and the default route
# of $WARP_TABLE becomes a multipath route over all of them: the kernel pins
# every connection to one interface by a hash of its addresses and ports. The
# route and the fwmark rule are built by ROUTES_HELPER from each interface's
# PostUp / PreDown — PreDown, because deleting an interface that a multipath
# route points at makes the kernel drop the whole route. The watchdog takes a
# dead interface out of the route by putting a marker into DRAIN_DIR.
ROUTES_HELPER="${APP_DIR}/routes.sh"
DRAIN_DIR="/run/vps-warp"
MP_SYSCTL_FILE="/etc/sysctl.d/99-vps-warp-multipath.conf"

# Endpoint pool (TSPU/DPI evasion: what matters is entropy, not the lowest RTT).
CF_SUBNETS=("188.114.96" "188.114.97")
CF_PORTS=(2408 500 4500 1701)

# How many endpoint re-rolls the installer tries to bring the egress country
# in line with the server's (see cf_country). The watchdog keeps
# trying afterwards, so this only bounds the install time.
GEO_TRIES=10

# Self-update source of truth. MUST point at YOUR repo — `vps-warp update`
# downloads and runs this as root.
RAW_URL="https://raw.githubusercontent.com/Chara-Freedom/vps-warp/main/warp_install.sh"

# Persist WARP+ license to disk (0600) so `vps-warp update` keeps it without
# re-entry. OFF by default: on a seized/compromised node the plaintext key is
# an extra leak point. Set to 1 only if you accept that trade-off.
PERSIST_LICENSE=0

# --- Colors & Styling ---
C_RST="\e[0m"
C_BLD="\e[1m"
C_CYN="\e[36m"
C_GRN="\e[32m"
C_YLW="\e[33m"
C_RED="\e[31m"
C_GRY="\e[90m"

# --- Helpers ---
function step()  { echo -e "\n${C_CYN}▶${C_RST} ${C_BLD}$1${C_RST}"; }
function done_() { echo -e "  ${C_GRN}✔${C_RST} ${C_GRY}$1${C_RST}"; }
function fail()  { echo -e "\n  ${C_RED}✖ Error:${C_RST} $1\n"; exit 1; }
function warn()  { echo -e "  ${C_YLW}⚠${C_RST} ${C_YLW}$1${C_RST}"; }

# Read a single line, preferring the controlling terminal so `curl ... | bash`
# (where stdin is the pipe) can still prompt. `[[ -e /dev/tty ]]` is not enough:
# the device node exists even with no controlling tty (setsid/cron/systemd),
# where opening it fails. So actually probe that /dev/tty is openable; otherwise
# fall back to stdin. Returns read's exit status so callers can detect EOF and
# bail instead of spinning (see select_language).
function ask() {
    local __var="$1" __prompt="$2" __reply __rc
    if { true </dev/tty; } 2>/dev/null; then
        read -r -p "$__prompt" __reply </dev/tty; __rc=$?
    else
        read -r -p "$__prompt" __reply; __rc=$?
    fi
    printf -v "$__var" '%s' "$__reply"
    return $__rc
}

function print_logo() {
    clear
    echo -e "${C_CYN}"
    echo '  ██╗    ██╗ █████╗ ██████╗ ██████╗ '
    echo '  ██║    ██║██╔══██╗██╔══██╗██╔══██╗'
    echo '  ██║ █╗ ██║███████║██████╔╝██████╔╝'
    echo '  ██║███╗██║██╔══██║██╔══██╗██╔═══╝ '
    echo '  ╚███╔███╔╝██║  ██║██║  ██║██║     '
    echo '   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     '
    echo -e "${C_GRN}    P R O   E D I T I O N  (Xray)   ${C_RST}"
    echo -e "${C_GRY}  ─────────────── v${SCRIPT_VERSION} ───────────${C_RST}\n"
}

# --- Language Selection ---
function select_language {
    print_logo
    echo -e "  🌍 ${C_BLD}Choose language / Выберите язык:${C_RST}"
    echo -e "     ${C_CYN}[1]${C_RST} English"
    echo -e "     ${C_CYN}[2]${C_RST} Русский\n"

    while true; do
        # On EOF / no controlling tty (e.g. a non-interactive `vps-warp update`
        # re-run) fall back to English rather than busy-looping the prompt.
        ask choice "  > " || { SCRIPT_LANG="en"; break; }
        # shellcheck disable=SC2154  # `choice` is set indirectly by ask() via printf -v
        case $choice in
            1) SCRIPT_LANG="en"; break ;;
            2) SCRIPT_LANG="ru"; break ;;
            *) warn "Please enter 1 or 2" ;;
        esac
    done
}

function t() {
    local key="$1"
    if [[ "$SCRIPT_LANG" == "ru" ]]; then
        case "$key" in
            "root_req") echo "Требуются права root (sudo)" ;;
            "clean") echo "Очистка старых версий..." ;;
            "clean_ok") echo "Система очищена" ;;
            "deps") echo "Установка зависимостей (WireGuard, iptables, ping)..." ;;
            "deps_ok") echo "Зависимости установлены" ;;
            "deps_err") echo "Ошибка установки зависимостей" ;;
            "no_pm") echo "Не найден поддерживаемый пакетный менеджер (apt/dnf/yum/zypper/pacman/apk/emerge)" ;;
            "no_systemd") echo "systemd не обнаружен — автозапуск туннеля и watchdog работать не будут (нужен ручной запуск/другой init)" ;;
            "wgcf") echo "Загрузка ядра wgcf..." ;;
            "wgcf_ok") echo "Ядро установлено" ;;
            "wgcf_resolve_err") echo "Не удалось узнать последнюю версию wgcf: GitHub не ответил. Текущая установка WARP не тронута, попробуйте позже." ;;
            "reg") echo "Регистрация в сети Cloudflare..." ;;
            "reg_ok") echo "Профиль готов" ;;
            "reg_err") echo "Регистрация не удалась: Cloudflare отклонил запросы (rate-limit или блокировка IP хостинга). Попробуйте позже или с другого IP." ;;
            "plus_ask") echo "🔑 Введите ключ WARP+ (или нажмите Enter для бесплатной версии):" ;;
            "plus_keep_hint") echo "(Enter — оставить сохранённый ключ)" ;;
            "plus_apply") echo "Активация WARP+..." ;;
            "plus_ok") echo "Лицензия активирована!" ;;
            "plus_err") echo "Ошибка ключа, используем базовый тариф." ;;
            "opt") echo "Глубокая оптимизация Xray (MTU, MSS Clamping, IPv4)..." ;;
            "rp_ok") echo "rp_filter не строгий — обратный трафик WARP пройдёт" ;;
            "rp_fixed") echo "rp_filter переведён из strict в loose и закреплён:" ;;
            "opt_ok") echo "Сетевой стек настроен" ;;
            "start") echo "Запуск туннеля..." ;;
            "start_ok") echo "Интерфейс поднят" ;;
            "start_err") echo "Не удалось поднять интерфейс. Смотрите: journalctl -u" ;;
            "handshake") echo "Ожидание ответа сети (Handshake)..." ;;
            "hs_ok") echo "Соединение установлено! Задержка:" ;;
            "geo") echo "Проверка страны выхода WARP..." ;;
            "geo_ok") echo "Страна выхода совпадает со страной сервера:" ;;
            "geo_rerolls") echo "перебросов endpoint:" ;;
            "tuple_kept") echo "Порт и endpoint сохранены, выход прежний:" ;;
            "tuple_new") echo "Порт и endpoint:" ;;
            "geo_skip") echo "Не удалось определить страну сервера или выхода — проверка пропущена, её повторит watchdog" ;;
            "geo_fail") echo "Страна выхода не совпала со страной сервера (выход / сервер), watchdog продолжит попытки:" ;;
            "geo_off") echo "Проверка выключена (--no-egress-check), включить: --egress-check" ;;
            "watchdog") echo "Установка Smart Watchdog (Systemd)..." ;;
            "watchdog_ok") echo "Watchdog активирован" ;;
            "finish") echo "Установка завершена!" ;;
            "help") echo "Используйте команду vps-warp для управления" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            "root_req") echo "Root privileges required (sudo)" ;;
            "clean") echo "Cleaning up old versions..." ;;
            "clean_ok") echo "System cleaned" ;;
            "deps") echo "Installing dependencies (WireGuard, iptables, ping)..." ;;
            "deps_ok") echo "Dependencies installed" ;;
            "deps_err") echo "Dependency installation failed" ;;
            "no_pm") echo "No supported package manager found (apt/dnf/yum/zypper/pacman/apk/emerge)" ;;
            "no_systemd") echo "systemd not detected — tunnel autostart and watchdog will not work (manual start / other init needed)" ;;
            "wgcf") echo "Downloading wgcf core..." ;;
            "wgcf_ok") echo "Core installed" ;;
            "wgcf_resolve_err") echo "Could not resolve the latest wgcf version: GitHub did not answer. The current WARP setup is untouched; retry later." ;;
            "reg") echo "Registering Cloudflare account..." ;;
            "reg_ok") echo "Profile ready" ;;
            "reg_err") echo "Registration failed: Cloudflare rejected the requests (rate limit or host IP block). Retry later or from another IP." ;;
            "plus_ask") echo "🔑 Enter WARP+ key (or press Enter for free tier):" ;;
            "plus_keep_hint") echo "(Enter — keep the saved key)" ;;
            "plus_apply") echo "Activating WARP+..." ;;
            "plus_ok") echo "License activated!" ;;
            "plus_err") echo "Key error, using free tier." ;;
            "opt") echo "Deep Xray Optimization (MTU, MSS Clamping, IPv4)..." ;;
            "rp_ok") echo "rp_filter is not strict — WARP return traffic will pass" ;;
            "rp_fixed") echo "rp_filter lowered from strict to loose and persisted:" ;;
            "opt_ok") echo "Network stack optimized" ;;
            "start") echo "Starting tunnel..." ;;
            "start_ok") echo "Interface is up" ;;
            "start_err") echo "Interface failed to come up. See: journalctl -u" ;;
            "handshake") echo "Waiting for network handshake..." ;;
            "hs_ok") echo "Connection established! Latency:" ;;
            "geo") echo "Checking WARP egress country..." ;;
            "geo_ok") echo "Egress country matches the server:" ;;
            "geo_rerolls") echo "endpoint re-rolls:" ;;
            "tuple_kept") echo "Port and endpoint kept, the exit stays the same:" ;;
            "tuple_new") echo "Port and endpoint:" ;;
            "geo_skip") echo "Could not determine the server or egress country — check skipped, the watchdog will retry it" ;;
            "geo_fail") echo "Egress country does not match the server (egress / server), the watchdog will keep trying:" ;;
            "geo_off") echo "Check is off (--no-egress-check), turn it back on with --egress-check" ;;
            "watchdog") echo "Installing Smart Watchdog (Systemd)..." ;;
            "watchdog_ok") echo "Watchdog activated" ;;
            "finish") echo "Installation complete!" ;;
            "help") echo "Use vps-warp command to manage" ;;
            *) echo "$key" ;;
        esac
    fi
}

# --- Dependencies (distro-agnostic) ---
# Presence is verified with `command -v` (works on any distro), so only the
# commands that are actually missing get installed — through whichever package
# manager the system ships with (apt / dnf / yum / zypper / pacman / apk / emerge).

# Echo the first supported package manager found, or return 1 if none.
function detect_pm() {
    local pm
    for pm in apt-get dnf yum zypper pacman apk emerge; do
        command -v "$pm" &>/dev/null && { echo "$pm"; return 0; }
    done
    return 1
}

# Translate a required command into the package that provides it for $pm.
function pkg_name() {
    local cmd="$1" pm="$2"
    case "$pm" in
        emerge)  # Gentoo (Portage atoms)
            case "$cmd" in
                wg-quick) echo "net-vpn/wireguard-tools" ;;
                iptables) echo "net-firewall/iptables" ;;
                ip)       echo "sys-apps/iproute2" ;;
                ping)     echo "net-misc/iputils" ;;
                curl)     echo "net-misc/curl" ;;
                wget)     echo "net-misc/wget" ;;
            esac ;;
        dnf|yum) # Fedora / RHEL family
            case "$cmd" in
                wg-quick) echo "wireguard-tools" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute" ;;
                ping)     echo "iputils" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
            esac ;;
        pacman|zypper) # Arch/Manjaro, openSUSE (identical names)
            case "$cmd" in
                wg-quick) echo "wireguard-tools" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute2" ;;
                ping)     echo "iputils" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
            esac ;;
        apk)     # Alpine — ping ships in its own package, busybox's lacks -m
            case "$cmd" in
                wg-quick) echo "wireguard-tools" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute2" ;;
                ping)     echo "iputils-ping" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
            esac ;;
        *)       # apt-get (Debian / Ubuntu) — wireguard metapackage keeps the
                 # kernel-module fallback for older kernels, as the original did.
            case "$cmd" in
                wg-quick) echo "wireguard" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute2" ;;
                ping)     echo "iputils-ping" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
            esac ;;
    esac
}

# Install the given packages quietly with the detected package manager.
function pm_install() {
    local pm="$1"; shift
    case "$pm" in
        apt-get) apt-get update -qq &>/dev/null
                 DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" &>/dev/null ;;
        dnf)     dnf install -y "$@" &>/dev/null ;;
        yum)     yum install -y "$@" &>/dev/null ;;
        # --needed skips already-present packages; these are leaf deps, so the
        # -Sy partial-upgrade caveat is low risk here.
        pacman)  pacman -Sy --needed --noconfirm "$@" &>/dev/null ;;
        zypper)  zypper --non-interactive --quiet install "$@" &>/dev/null ;;
        apk)     apk add --no-cache "$@" &>/dev/null ;;
        emerge)  emerge --quiet --noreplace "$@" &>/dev/null ;;
        *)       return 1 ;;
    esac
}

# Verify required commands and install only what is missing.
#
# `ping` is a hard requirement, not a nicety: the watchdog's health check IS a
# ping through the tunnel. Without the binary every check reports failure, so
# the watchdog rotates the endpoint and restarts wg-quick every 3 minutes
# forever on an otherwise healthy link.
function install_deps() {
    local required=(wg-quick ip iptables ping curl wget)
    local cmd pm pkg
    local missing_cmds=() missing_pkgs=()

    for cmd in "${required[@]}"; do
        command -v "$cmd" &>/dev/null || missing_cmds+=("$cmd")
    done
    [[ ${#missing_cmds[@]} -eq 0 ]] && return 0   # already satisfied

    pm=$(detect_pm) || fail "$(t "no_pm")"

    for cmd in "${missing_cmds[@]}"; do
        pkg=$(pkg_name "$cmd" "$pm")
        [[ -n "$pkg" ]] && missing_pkgs+=("$pkg")
    done

    pm_install "$pm" "${missing_pkgs[@]}" || fail "$(t "deps_err") ($pm)"

    # Re-verify: a package manager can exit 0 and still not provide the binary
    # (wrong package name on an exotic distro, busybox-only image).
    for cmd in "${missing_cmds[@]}"; do
        command -v "$cmd" &>/dev/null || fail "$(t "deps_err") — '$cmd' still missing"
    done
}

# --- Reverse-path filter ---
# This tunnel is asymmetric by construction: Xray's marked packets leave via
# $WARP_IFACE (table $WARP_TABLE) while the box's default route stays on the
# main NIC. Decrypted replies arrive back on $WARP_IFACE carrying no fwmark, so
# the reverse-path lookup misses our `fwmark` rule, lands in the main table,
# resolves to the default route — and strict rp_filter (=1) drops them. Symptom
# is nasty precisely because nothing looks broken: handshake fresh, interface
# ACTIVE, zero traffic through the tunnel.
#
# wg-quick does not cover this for us. Its src_valid_mark=1 lives in
# add_default(), which add_route() only reaches when Table is auto/unset — with
# an explicit `Table = <number>` that branch is never taken.
#
# Xray-core >= 26.6.27 writes rp_filter itself on startup, but that fails
# inside a containerised node with read-only /proc/sys, so it cannot be relied
# on either.
#
# Loose (=2), not 0: still drops martian/unroutable sources, only permits the
# asymmetric path. Strict (=1) is the sole value we touch — an operator who
# deliberately set 0 keeps it. Effective value is max(conf.all, conf.<iface>),
# so `all` must come down too; setting just the interface is a no-op.
RP_SYSCTL_FILE="/etc/sysctl.d/99-vps-warp.conf"
function relax_rp_filter() {
    local scope cur touched=()
    for scope in all default; do
        cur=$(cat "/proc/sys/net/ipv4/conf/${scope}/rp_filter" 2>/dev/null) || continue
        [[ "$cur" == "1" ]] || continue
        sysctl -qw "net.ipv4.conf.${scope}.rp_filter=2" 2>/dev/null && touched+=("$scope")
    done

    if [[ ${#touched[@]} -eq 0 ]]; then
        rp_status="$(t "rp_ok")"
        return 0
    fi

    # Persist, or a reboot silently reinstates strict mode and the tunnel goes
    # dark with a perfectly healthy-looking handshake.
    {
        echo "# Added by vps-warp: policy-routed WARP needs a non-strict"
        echo "# reverse-path filter. Removed by 'vps-warp uninstall'."
        for scope in "${touched[@]}"; do
            echo "net.ipv4.conf.${scope}.rp_filter = 2"
        done
    } > "$RP_SYSCTL_FILE"
    chmod 644 "$RP_SYSCTL_FILE"
    rp_status="$(t "rp_fixed") (${touched[*]})"
}

# --- Egress country ---
# Cloudflare hands each WARP session to one of the machines in the nearest data
# centre, chosen by a hash of the OUTER tuple (our ip:port -> endpoint:port).
# Some of those machines egress from addresses that Cloudflare itself
# geolocates to another country: from a server in Tokyo, about half of the
# tuples came out of 104.28.x addresses labelled DE, the rest JP. The same
# tuple lands on the same machine every time; a new tuple is a new draw. The
# WARP account plays no part — one account gave JP and DE on different tuples.
#
# Hence the local port is picked ONCE, at the first install, and never changes
# afterwards: every rotation (the watchdog, `vps-warp rotate`, the re-rolls
# below) changes only the endpoint, and a reinstall or `vps-warp update` keeps
# both. With the port fixed the endpoint alone is the key to the exit: the same
# endpoint brings back the same exit, a new one is a new draw. Changing the port
# as well reaches no exit the endpoint cannot — the data centre's pool is the
# same, and 2 x 254 x 4 endpoints already outnumber its exits — it would only
# scramble every endpoint -> exit pairing seen so far. Unpinned, the kernel
# picks a fresh port on every `wg-quick up`, so each restart or reboot would
# silently move the exit.

# Two-letter country Cloudflare assigns to the source of this request. Extra
# curl arguments pick the path (`--interface warp` = through the tunnel).
# Prints nothing on any failure — callers treat empty as "unknown", never as
# a mismatch.
function cf_country() {
    curl -4 -s -m 8 "$@" https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1 == "loc" { print $2; exit }'
}

# A random UDP port in 20000–49999 that nothing is bound to. `ss` may be
# missing on minimal images; a collision there is unlikely, and wg-quick would
# fail loudly rather than silently.
function random_free_port() {
    local p
    for _ in {1..20}; do
        p=$(( 20000 + RANDOM % 30000 ))
        command -v ss &>/dev/null && ss -Hlun "sport = :$p" 2>/dev/null | grep -q . && continue
        break
    done
    echo "$p"
}

# A random endpoint from the pool. $RANDOM instead of shuf: minimal/busybox
# images don't always ship shuf, and a silently-empty part would write a
# malformed Endpoint line.
function random_endpoint() {
    echo "${CF_SUBNETS[RANDOM % ${#CF_SUBNETS[@]}]}.$(( RANDOM % 254 + 1 )):${CF_PORTS[RANDOM % ${#CF_PORTS[@]}]}"
}

# Re-roll the exit on the LIVE interface: a random endpoint (the local port
# stays, see above), applied by dropping and re-adding the peer. Dropping the
# peer resets the session, so the next packet does a fresh handshake on the
# new tuple — traffic is back in ~0.2 s. Changing the tuple without that reset
# keeps the old session, which the new Cloudflare machine does not know:
# traffic then stalls for 5+ s until WireGuard re-handshakes on its own.
#
# Deliberately NOT `systemctl restart`: wg-quick's PostDown removes the fwmark
# rule, so marked traffic would leave the box unencapsulated while the tunnel
# is down, and several draws back to back trip systemd's start rate limit
# (5 starts / 10 s) and leave the unit failed — tunnel gone until a human
# steps in. The peer swap keeps the interface and the rule in place.
# The new endpoint goes into the config as well, so it survives a restart.
function reroll_endpoint() {
    local iface="$1" conf="/etc/wireguard/$1.conf" ep pub
    pub=$(wg show "$iface" peers 2>/dev/null | head -1)
    [[ -n "$pub" ]] || return 1
    ep=$(random_endpoint)
    wg set "$iface" peer "$pub" remove 2>/dev/null
    wg set "$iface" peer "$pub" endpoint "$ep" allowed-ips 0.0.0.0/0 persistent-keepalive 15
    sed -i "s/^Endpoint = .*/Endpoint = ${ep}/" "$conf"
}

# Per-account names. Account 1 keeps the paths every earlier version used, so
# an upgrade with one account changes nothing on disk.
function iface_of()    { [[ $1 -eq 1 ]] && echo "$WARP_IFACE"     || echo "${WARP_IFACE}$1"; }
function wgcf_dir_of() { [[ $1 -eq 1 ]] && echo "$WGCF_DIR"       || echo "${WGCF_DIR}-$1"; }
function state_of()    { [[ $1 -eq 1 ]] && echo "$WATCHDOG_STATE" || echo "${STATE_DIR}/watchdog-$(iface_of "$1").state"; }

# --- Pre-flight Checks ---
[[ $EUID -ne 0 ]] && fail "$(t "root_req")"

# --- Options ---
# --no-egress-check turns the egress country check off (installer and
# watchdog), --egress-check turns it back on; without either, the previous
# choice stands. It lives in STATE_DIR because `vps-warp update` re-runs this
# script with no arguments.
# Off is for setups where a different country is the very point of WARP (often
# WARP chained into WARP, mostly on Russian hosts) — the check would keep
# re-rolling it away — and for those where a mismatch simply does not matter.
#
# --accounts N (1–$MAX_ACCOUNTS) sets how many WARP accounts share the traffic;
# without it the previous number stands (1 on a first install). Both flags are
# validated before anything on the box changes.
EGRESS_ARG=""
ACCOUNTS_ARG=""
ACCOUNTS_SET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-egress-check|--egress-check) EGRESS_ARG="$1" ;;
        --accounts)   ACCOUNTS_SET=1; ACCOUNTS_ARG="${2:-}"; [[ $# -ge 2 ]] && shift ;;
        --accounts=*) ACCOUNTS_SET=1; ACCOUNTS_ARG="${1#*=}" ;;
        *) fail "Unknown option: $1 (supported: --no-egress-check, --egress-check, --accounts N)" ;;
    esac
    shift
done
if [[ $ACCOUNTS_SET -eq 1 ]]; then
    [[ "$ACCOUNTS_ARG" =~ ^[0-9]+$ && "$ACCOUNTS_ARG" -ge 1 && "$ACCOUNTS_ARG" -le $MAX_ACCOUNTS ]] \
        || fail "--accounts takes a number from 1 to ${MAX_ACCOUNTS}, got '${ACCOUNTS_ARG}'"
fi
OLD_ACCOUNTS=$(cat "$ACCOUNTS_FILE" 2>/dev/null)
[[ "$OLD_ACCOUNTS" =~ ^[0-9]+$ && "$OLD_ACCOUNTS" -ge 1 && "$OLD_ACCOUNTS" -le $MAX_ACCOUNTS ]] || OLD_ACCOUNTS=1
ACCOUNTS=${ACCOUNTS_ARG:-$OLD_ACCOUNTS}
IFACES=()
for (( k = 1; k <= ACCOUNTS; k++ )); do IFACES+=("$(iface_of "$k")"); done
case "$EGRESS_ARG" in
    --no-egress-check) mkdir -p "$STATE_DIR" && touch "$EGRESS_OFF_FILE" ;;
    --egress-check)    rm -f "$EGRESS_OFF_FILE" ;;
esac

# --- Start ---
select_language
print_logo

# Steps 7–9 (start/watchdog) rely on systemctl — warn upfront on non-systemd
# inits (Alpine, OpenRC Gentoo, …). `/run/systemd/system` exists only when
# systemd is the running init, so this catches more than `command -v systemctl`.
[[ -d /run/systemd/system ]] || warn "$(t "no_systemd")"

# 2. Dependencies (distro-agnostic — see install_deps)
step "📦 $(t "deps")"
install_deps
done_ "$(t "deps_ok")"

# 3. WGCF Download
# Fetches the current "latest" (auto-updates are the point; a frozen wgcf can
# break compat). No checksum verification: wgcf ships no signatures, and a hash
# pulled from the same GitHub release over the same HTTPS as the binary adds no
# real integrity guarantee — an attacker able to swap the binary swaps the hash
# too. HTTPS already covers transport MITM. The only residual risk (an upstream
# release compromise) would require pinning a known-good hash in *this* repo,
# which is deliberately not done here (it freezes wgcf). Kept from PR #2, not as
# security but as hygiene: `-f` (never land a 404/5xx page as an executable) and
# tmp + `install` (no half-written binary at the live path if curl dies).
step "⚙️  $(t "wgcf")"
LATEST_URL=$(curl -Ls -m 20 -w "%{url_effective}" -o /dev/null "https://github.com/ViRb3/wgcf/releases/latest")
WGCF_VERSION=$(basename "$LATEST_URL")
# No pinned fallback tag: this lookup and the download below both go to
# github.com over HTTPS, so whatever breaks one (a censor, a rate limit, no
# route) breaks the other too. Stopping here is harmless: the previous install
# is cleaned up only once the new config is ready (just before step 7).
[[ "$WGCF_VERSION" == v* ]] || fail "$(t "wgcf_resolve_err")"
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && WGCF_ARCH="arm64" || WGCF_ARCH="amd64"
WGCF_DL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}"

WGCF_TMP=$(mktemp) || fail "mktemp failed"
curl -fsSL "$WGCF_DL" -o "$WGCF_TMP" || { rm -f "$WGCF_TMP"; fail "Download failed: $WGCF_DL"; }
install -m 0755 "$WGCF_TMP" /usr/local/bin/wgcf || { rm -f "$WGCF_TMP"; fail "Install failed"; }
rm -f "$WGCF_TMP"
done_ "$(t "wgcf_ok") (v${WGCF_VERSION#v})"

# 4. Registration (Protected from Rate Limits)
#
# Working directory is $WGCF_DIR, not $HOME: sudo's env_reset makes $HOME
# unpredictable, and a stray wgcf-account.toml in an operator's home directory
# is easy to lose track of. Existing installs are migrated in place.
#
# One working directory per account; an account that already exists is reused,
# so a reinstall or `vps-warp update` keeps every account it had. New accounts
# are registered a few seconds apart: Cloudflare rate-limits registrations.
step "🛡️  $(t "reg")"
mkdir -p "$WGCF_DIR"
chmod 700 "$STATE_DIR" "$WGCF_DIR"
[[ -f "$HOME/wgcf-account.toml" && ! -f "$WGCF_DIR/wgcf-account.toml" ]] \
    && mv "$HOME/wgcf-account.toml" "$WGCF_DIR/wgcf-account.toml"

registered=0
for (( k = 1; k <= ACCOUNTS; k++ )); do
    dir=$(wgcf_dir_of "$k")
    mkdir -p "$dir" && chmod 700 "$dir"
    cd "$dir" || fail "Cannot enter $dir"
    if [[ ! -f wgcf-account.toml ]]; then
        [[ $registered -gt 0 ]] && sleep 5
        for _ in {1..3}; do
            timeout 40 bash -c 'yes | wgcf register' &>/dev/null && break
            sleep 3
        done
        registered=$(( registered + 1 ))
    fi
    # Distinguish "registration never succeeded" from "generate itself broke" — the
    # original reported both as the same opaque message.
    [[ -f wgcf-account.toml ]] || fail "$(t "reg_err")"
    chmod 600 wgcf-account.toml
    wgcf generate &>/dev/null || fail "Config generation failed (wgcf generate, $dir)."
done
cd "$WGCF_DIR" || fail "Cannot enter $WGCF_DIR"
done_ "$(t "reg_ok")$([[ $ACCOUNTS -gt 1 ]] && echo " (${ACCOUNTS})")"

# 5. WARP+
# Reuse a previously saved license (if PERSIST_LICENSE=1) so WARP+ survives an
# update re-run without re-entry.
SAVED_LICENSE=""
[[ "$PERSIST_LICENSE" == "1" && -f "$LICENSE_FILE" ]] && SAVED_LICENSE=$(tr -cd 'a-zA-Z0-9-' < "$LICENSE_FILE")
echo ""
echo -e "  $(t "plus_ask")"
[[ -n "$SAVED_LICENSE" ]] && echo -e "  ${C_GRY}$(t "plus_keep_hint")${C_RST}"
ask WARP_LICENSE "  > "
# Empty input + a saved key => keep the existing WARP+ license.
[[ -z "$WARP_LICENSE" && -n "$SAVED_LICENSE" ]] && WARP_LICENSE="$SAVED_LICENSE"
if [[ -n "$WARP_LICENSE" ]]; then
    # Security: input sanitisation (letters, digits and dashes only)
    WARP_LICENSE=$(printf '%s' "$WARP_LICENSE" | tr -cd 'a-zA-Z0-9-')
    step "💎 $(t "plus_apply")"
    if wgcf update --license-key "$WARP_LICENSE" &>/dev/null; then
        wgcf generate &>/dev/null
        if [[ "$PERSIST_LICENSE" == "1" ]]; then
            mkdir -p "$STATE_DIR"
            printf '%s\n' "$WARP_LICENSE" > "$LICENSE_FILE"
            chmod 600 "$LICENSE_FILE"
        fi
        done_ "$(t "plus_ok")"
    else
        warn "$(t "plus_err")"
    fi
fi

# 6. Ultimate Xray Tweaks (Production Grade Injection)
step "🛠️  $(t "opt")"

# Turn account $1's wgcf profile into its final WireGuard config.
#
# Table = off: wg-quick installs no routes and no rules of its own. The default
# route of $WARP_TABLE (one interface, or a multipath route over several) and
# the fwmark rule come from ROUTES_HELPER, which every interface runs in PostUp
# and in PreDown. Only packets carrying fwmark $WARP_FWMARK (i.e. Xray's) are
# steered into the tunnel, so the host's default route is untouched.
#
# PreDown, not PostDown: by PostDown the interface is gone, and deleting an
# interface that a multipath route points at makes the kernel drop the whole
# route, the other accounts' share included. PreDown rebuilds the route without
# this interface first. When the last interface goes down the helper removes
# the fwmark rule, as PostDown did in earlier versions.
#
# The MSS clamp deletes its own rule before adding it. Without that, a hard
# reboot or an OOM-killed wg-quick leaves the rule behind and the next start
# stacks a duplicate; after a few crash cycles the mangle chain holds N copies.
#
# Local port and endpoint. The outer tuple decides which Cloudflare machine the
# account egresses from, i.e. the exit address and country (see the note above
# cf_country). A reinstall or `vps-warp update` keeps the pair each account
# already has, so an update does not silently move an exit; a new account picks
# both at random from the pool (CF_SUBNETS / CF_PORTS at the top) — for anti-DPI
# what matters is endpoint entropy, not the lowest ICMP RTT, hence no
# scan_endpoints pass. The port is pinned with or without --no-egress-check:
# the check relies on it, and with the check off it keeps an exit chosen by
# `vps-warp rotate`. Only well-formed old values are reused (they go into sed).
USED_PORTS=()
function build_conf() {
    local k="$1" iface conf old_port old_ep port ep tag=""
    iface=$(iface_of "$k")
    conf="$(wgcf_dir_of "$k")/wgcf-profile.conf"
    [[ -f "$conf" ]] || fail "$conf not found"
    [[ $ACCOUNTS -gt 1 ]] && tag="${iface}: "

    # Strip wgcf's defaults so only our values remain
    sed -i '/^DNS =/d'   "$conf"
    sed -i '/^MTU =/d'   "$conf"
    sed -i '/^Table =/d' "$conf"

    # Blackhole Fix: drop IPv6 entirely
    sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "$conf"
    sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$conf"
    sed -i 's/,\s*::\/0//' "$conf"
    sed -i '/AllowedIPs = ::\/0/d' "$conf"

    # Inject routing into [Interface] (see the note above build_conf).
    sed -i "/^\[Interface\]/a\\
MTU = ${WARP_MTU}\\
Table = off\\
PostUp = ${ROUTES_HELPER} || true\\
PreDown = ${ROUTES_HELPER} --without ${iface} || true\\
PostUp = iptables -t mangle -D POSTROUTING -o ${iface} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WARP_MSS} 2>/dev/null || true\\
PostUp = iptables -t mangle -A POSTROUTING -o ${iface} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WARP_MSS} || true\\
PostDown = iptables -t mangle -D POSTROUTING -o ${iface} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WARP_MSS} 2>/dev/null || true\\
" "$conf"

    # Inject Keepalive into [Peer]
    sed -i '/^\[Peer\]/a\
PersistentKeepalive = 15\
' "$conf"

    old_port=$(awk '$1 == "ListenPort" { print $3; exit }' "/etc/wireguard/${iface}.conf" 2>/dev/null)
    old_ep=$(awk '$1 == "Endpoint" { print $3; exit }' "/etc/wireguard/${iface}.conf" 2>/dev/null)
    [[ "$old_port" =~ ^[0-9]{1,5}$ && "$old_port" -ge 1 && "$old_port" -le 65535 ]] || old_port=""
    [[ "$old_ep" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || old_ep=""
    port=$old_port
    while [[ -z "$port" || " ${USED_PORTS[*]} " == *" ${port} "* ]]; do port=$(random_free_port); done
    USED_PORTS+=("$port")
    ep=${old_ep:-$(random_endpoint)}
    sed -i "s/^Endpoint = .*/Endpoint = ${ep}/" "$conf"
    sed -i "/^\[Interface\]/a ListenPort = ${port}" "$conf"

    if [[ "$port" == "$old_port" && -n "$old_ep" ]]; then
        done_ "$(t "tuple_kept") ${tag}${port} -> ${ep}"
    else
        done_ "$(t "tuple_new") ${tag}${port} -> ${ep}"
    fi
}
for (( k = 1; k <= ACCOUNTS; k++ )); do build_conf "$k"; done

# Must happen before the interfaces come up: `default` is the template new
# interfaces inherit from, so they pick up the relaxed value at creation.
rp_status=""
relax_rp_filter
done_ "$(t "opt_ok")"
[[ -n "$rp_status" ]] && done_ "$rp_status"

# Cleanup of the previous install — deliberately only HERE, once the new
# configs are ready. It used to run first, so any failure in between (wgcf
# download, registration, `wgcf generate`) left the box with the tunnel down
# and the watchdog deleted. While wg-quick is down the fwmark rule is gone, so
# Xray's marked traffic leaves from the server's real IP; from here to step 7
# that window is well under a second.
step "🗑️  $(t "clean")"
max_k=$(( ACCOUNTS > OLD_ACCOUNTS ? ACCOUNTS : OLD_ACCOUNTS ))
for (( k = 1; k <= max_k; k++ )); do
    systemctl disable "wg-quick@$(iface_of "$k")" --now &>/dev/null || true
done
# Accounts beyond the new number go away with everything they owned.
for (( k = ACCOUNTS + 1; k <= OLD_ACCOUNTS; k++ )); do
    rm -rf "/etc/wireguard/$(iface_of "$k").conf" "$(wgcf_dir_of "$k")" "$(state_of "$k")"
done
systemctl disable warp-watchdog.timer --now &>/dev/null || true
rm -rf /opt/warp-native /opt/vps-warp /etc/cron.d/warp-native /usr/local/bin/warp /etc/systemd/system/warp-watchdog.* "$DRAIN_DIR" &>/dev/null
systemctl daemon-reload
done_ "$(t "clean_ok")"

# Routes helper (see ROUTES_HELPER at the top). Written before any interface
# starts, because their PostUp runs it. Same two-part generation as the
# watchdog below: a header of values injected with printf %q (safe quoting)
# followed by a *quoted* heredoc, so nothing in the body needs escaping.
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" # Security: blocks local privilege escalation via the scripts
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# Generated by the vps-warp installer — edits are lost on update.'
    printf 'IFACES=(%s)\n'  "$(printf '%q ' "${IFACES[@]}")"
    printf 'FWMARK=%q\n'    "$WARP_FWMARK"
    printf 'TABLE=%q\n'     "$WARP_TABLE"
    printf 'DRAIN_DIR=%q\n' "$DRAIN_DIR"
} > "$ROUTES_HELPER"

cat >> "$ROUTES_HELPER" << 'RTEOF'
# Point the default route of $TABLE at the WARP interfaces that are up and not
# drained by the watchdog, and keep the fwmark rule while there is at least one
# of them. `--without IFACE` leaves that interface out (it runs from PreDown).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
without=""
[[ "$1" == "--without" ]] && without="$2"

# Interfaces come up in parallel at boot, and each one runs this from PostUp.
# Under the lock the last run sees every interface that is up, so the last
# write is the right one.
if command -v flock &>/dev/null; then
    exec 9>"${DRAIN_DIR}.lock"
    flock -w 10 9
fi

up=(); live=()
for i in "${IFACES[@]}"; do
    [[ "$i" == "$without" ]] && continue
    [[ -n "$(ip link show dev "$i" up 2>/dev/null)" ]] || continue
    up+=("$i")
    [[ -f "${DRAIN_DIR}/${i}" ]] || live+=("$i")
done
# Never drain down to nothing: if every interface that is up is drained, keep
# them all, the way a single tunnel that is down keeps its route.
[[ ${#live[@]} -eq 0 ]] && live=("${up[@]}")

rule_present() { ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$FWMARK") lookup ${TABLE}"; }

if [[ ${#live[@]} -eq 0 ]]; then
    ip route flush table "$TABLE" 2>/dev/null
    while rule_present; do ip rule del fwmark "$FWMARK" table "$TABLE" 2>/dev/null || break; done
    exit 0
fi

if [[ ${#live[@]} -eq 1 ]]; then
    ip route replace default dev "${live[0]}" table "$TABLE"
else
    hops=()
    for i in "${live[@]}"; do hops+=(nexthop dev "$i" weight 1); done
    ip route replace default table "$TABLE" "${hops[@]}"
fi
rule_present || ip rule add fwmark "$FWMARK" table "$TABLE"
exit 0
RTEOF
chmod 700 "$ROUTES_HELPER"

# With several accounts the kernel has to hash on ports as well: by addresses
# alone every connection to one destination would land on the same account.
if [[ $ACCOUNTS -gt 1 ]]; then
    sysctl -qw net.ipv4.fib_multipath_hash_policy=1
    {
        echo "# Added by vps-warp (--accounts): spread connections over the WARP"
        echo "# accounts by an L4 hash. Removed by 'vps-warp uninstall' or --accounts 1."
        echo "net.ipv4.fib_multipath_hash_policy = 1"
    } > "$MP_SYSCTL_FILE"
    chmod 644 "$MP_SYSCTL_FILE"
elif [[ -f "$MP_SYSCTL_FILE" ]]; then
    rm -f "$MP_SYSCTL_FILE"
    sysctl -qw net.ipv4.fib_multipath_hash_policy=0
fi

mkdir -p /etc/wireguard
for (( k = 1; k <= ACCOUNTS; k++ )); do
    install -m 600 "$(wgcf_dir_of "$k")/wgcf-profile.conf" "/etc/wireguard/$(iface_of "$k").conf"
    rm -f "$(wgcf_dir_of "$k")/wgcf-profile.conf"
done

WARP_LOCAL_IP=$(grep -oP '(?<=Address = )[0-9.]+' "/etc/wireguard/${WARP_IFACE}.conf" | head -1)

# 7. Start Services
step "🚀 $(t "start")"
for iface in "${IFACES[@]}"; do
    systemctl enable "wg-quick@${iface}" &>/dev/null
    # Previously this failure was swallowed and the run continued into the
    # handshake loop, which then blamed the network for a config error.
    systemctl restart "wg-quick@${iface}" &>/dev/null || fail "$(t "start_err") wg-quick@${iface}"
done
done_ "$(t "start_ok")"

# 8. Handshake Check
step "📡 $(t "handshake")"
for iface in "${IFACES[@]}"; do
    hs_ok=0
    for _ in {1..15}; do
        hs_ts=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$hs_ts" && "$hs_ts" -gt 0 ]]; then
            age=$(( $(date +%s) - hs_ts ))
            done_ "$(t "hs_ok") ${age}s$([[ $ACCOUNTS -gt 1 ]] && echo " (${iface})")"
            hs_ok=1
            break
        fi
        sleep 1
    done
    [[ $hs_ok -eq 0 ]] && warn "Handshake timeout on ${iface}. Interface is up, but connection might be blocked."
done

# 8b. Egress country (see the note above cf_country), for every account
step "🌍 $(t "geo")"
if [[ -f "$EGRESS_OFF_FILE" ]]; then
    done_ "$(t "geo_off")"
else
    SERVER_CC=$(cf_country)
    for iface in "${IFACES[@]}"; do
        tag=""
        [[ $ACCOUNTS -gt 1 ]] && tag=" (${iface})"
        WARP_CC=$(cf_country --interface "$iface")
        if [[ -z "$SERVER_CC" || -z "$WARP_CC" ]]; then
            warn "$(t "geo_skip")${tag}"
            continue
        fi
        geo_rerolls=0
        while [[ "$WARP_CC" != "$SERVER_CC" && $geo_rerolls -lt $GEO_TRIES ]]; do
            geo_rerolls=$(( geo_rerolls + 1 ))
            reroll_endpoint "$iface"
            WARP_CC=$(cf_country --interface "$iface")
        done
        if [[ "$WARP_CC" == "$SERVER_CC" ]]; then
            done_ "$(t "geo_ok") ${WARP_CC}$([[ $geo_rerolls -gt 0 ]] && echo " ($(t "geo_rerolls") ${geo_rerolls})")${tag}"
        else
            warn "$(t "geo_fail") ${WARP_CC:-?} / ${SERVER_CC}${tag}"
        fi
    done
fi

# 9. Systemd Watchdog (Triple Ping + Rotation Backoff)
step "🤖 $(t "watchdog")"
STATES=()
for (( k = 1; k <= ACCOUNTS; k++ )); do STATES+=("$(state_of "$k")"); done

# Two-part generation: a header of values injected with printf %q (safe quoting)
# followed by a *quoted* heredoc, so nothing in the body needs escaping.
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# Generated by the vps-warp installer — edits are lost on update.'
    printf 'IFACES=(%s)\n'   "$(printf '%q ' "${IFACES[@]}")"
    printf 'STATES=(%s)\n'   "$(printf '%q ' "${STATES[@]}")"
    printf 'FWMARK=%q\n'     "$WARP_FWMARK"
    printf 'TABLE=%q\n'      "$WARP_TABLE"
    printf 'EGRESS_OFF=%q\n' "$EGRESS_OFF_FILE"
    printf 'ROUTES=%q\n'     "$ROUTES_HELPER"
    printf 'DRAIN_DIR=%q\n'  "$DRAIN_DIR"
} > "$APP_DIR/watchdog.sh"

cat >> "$APP_DIR/watchdog.sh" << 'WDEOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Two-letter country Cloudflare assigns to the source of this request; extra
# curl arguments pick the path. Empty on any failure.
cf_country() {
    curl -4 -s -m 8 "$@" https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1 == "loc" { print $2; exit }'
}

# A new endpoint = a new draw of the egress machine. The local port is NOT
# changed: it was picked once, at install, and with it fixed the endpoint alone
# is the key to the exit (see the installer's note on the egress country).
SUBNETS=("188.114.96" "188.114.97")
PORTS=(2408 500 4500 1701)
pick_endpoint() {
    NEW_EP="${SUBNETS[RANDOM % ${#SUBNETS[@]}]}.$(( RANDOM % 254 + 1 )):${PORTS[RANDOM % ${#PORTS[@]}]}"
}

# Set when an interface was drained or came back; the shared route is rebuilt
# once, after all of them are checked.
changed=0

# Every account is checked on its own: handshake age and a ping bound to its
# interface. The ping does not go by fwmark: with several accounts the marked
# path is a multipath route, and a probe on it tests whichever interface the
# hash picks. A dead interface is drained — taken out of the shared route via a
# marker in DRAIN_DIR — until it is healthy again, so its share of connections
# does not vanish into it meanwhile. The routes helper never drains the last
# interface, so with one account the route stays as it is.
check_iface() {
    local IFACE="$1" STATE_FILE="$2" CONF="/etc/wireguard/$1.conf" P="WARP Watchdog"
    local hs_ts now age ping_ok healthy mark fails last_rot reason server_cc warp_cc
    local exp backoff pub try got dst
    [[ ${#IFACES[@]} -gt 1 ]] && P="WARP Watchdog [${IFACE}]"

    # Silent by design when the operator stopped the tunnel on purpose.
    systemctl is-active --quiet "wg-quick@${IFACE}" || return 0
    [[ -f "$CONF" ]] || { echo "${P}: $CONF missing, nothing to do"; return 0; }

    # Default to 0 *before* the arithmetic. `wg show` prints nothing when the
    # interface exists but has no peer yet, and $(( now -  )) is a syntax error,
    # not a zero — so the old code aborted right here instead of treating it as
    # "no handshake", which is exactly the state the watchdog exists to repair.
    hs_ts=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    hs_ts=${hs_ts:-0}
    now=$(date +%s)
    age=$(( now - hs_ts ))

    ping_ok=0
    for dst in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if ping -I "$IFACE" -c 1 -W 2 "$dst" &>/dev/null; then
            ping_ok=1
            break
        fi
    done

    healthy=1
    [[ "$hs_ts" -eq 0 || $age -gt 180 ]] && healthy=0
    [[ $ping_ok -eq 0 ]] && healthy=0

    mark="${DRAIN_DIR}/${IFACE}"
    if [[ $healthy -eq 1 ]]; then
        if [[ -f "$mark" ]]; then
            rm -f "$mark"
            changed=1
            [[ ${#IFACES[@]} -gt 1 ]] && echo "${P}: healthy again, back in the route"
        fi
    elif [[ ! -f "$mark" ]]; then
        mkdir -p "$DRAIN_DIR" && touch "$mark"
        changed=1
    fi

    # --- Rotation backoff ---
    # When Cloudflare is blocked wholesale rather than at one endpoint, rotating
    # cannot help, and a fixed 3-minute retry means restarting WireGuard 480 times
    # a day — which is itself a signature worth flagging. Back off exponentially,
    # capped at 30 min, and reset the moment the link recovers. A wrong egress
    # country (below) counts as a failure too, so a country Cloudflare cannot
    # serve from this data centre backs off the same way instead of churning.
    fails=0; last_rot=0
    [[ -f "$STATE_FILE" ]] && read -r fails last_rot < "$STATE_FILE" 2>/dev/null
    fails=${fails:-0}; last_rot=${last_rot:-0}

    # --- Egress country ---
    # Cloudflare picks the egress machine by a hash of the outer tuple (our
    # ip:port -> endpoint:port), and some machines egress from addresses it
    # geolocates to another country. A healthy tunnel can therefore still come out
    # in the wrong country. Unknown on either side is NOT a mismatch: a failed
    # probe must never churn the tunnel. With the check turned off
    # (--no-egress-check) nothing is probed and both stay unknown.
    reason="down"
    if [[ $healthy -eq 1 ]]; then
        server_cc=""; warp_cc=""
        if [[ ! -f "$EGRESS_OFF" ]]; then
            server_cc=$(cf_country)
            warp_cc=$(cf_country --interface "$IFACE")
        fi
        if [[ -z "$server_cc" || -z "$warp_cc" || "$warp_cc" == "$server_cc" ]]; then
            [[ $fails -ne 0 ]] && printf '0 %s\n' "$last_rot" > "$STATE_FILE"
            return 0
        fi
        reason="country"
    fi

    exp=$(( fails > 4 ? 4 : fails ))
    backoff=$(( 180 * (2 ** exp) ))
    [[ $backoff -gt 1800 ]] && backoff=1800
    if [[ $(( now - last_rot )) -lt $backoff ]]; then
        if [[ "$reason" == "country" ]]; then
            echo "${P}: egress country ${warp_cc} != server ${server_cc} (fail #${fails}), next re-roll in $(( backoff - (now - last_rot) ))s"
        else
            echo "${P}: still down (fail #${fails}), next rotation in $(( backoff - (now - last_rot) ))s"
        fi
        return 0
    fi

    if [[ "$reason" == "country" ]]; then
        # The tunnel is healthy, so re-roll it LIVE: drop and re-add the peer with
        # a new endpoint. That resets the session and the next packet handshakes
        # on the new tuple (~0.2 s). No systemctl restart here — five restarts
        # in a row trip systemd's start limit and leave the unit failed.
        pub=$(wg show "$IFACE" peers 2>/dev/null | head -1)
        # An endpoint is a coin toss, so several draws per run usually settle it
        # within one pass instead of leaving the wrong country up for backoff periods.
        for try in 1 2 3 4 5; do
            pick_endpoint
            wg set "$IFACE" peer "$pub" remove 2>/dev/null
            wg set "$IFACE" peer "$pub" endpoint "$NEW_EP" allowed-ips 0.0.0.0/0 persistent-keepalive 15
            sed -i "s/^Endpoint = .*/Endpoint = ${NEW_EP}/" "$CONF"
            got=$(cf_country --interface "$IFACE")
            if [[ "$got" == "$server_cc" ]]; then
                printf '0 %s\n' "$now" > "$STATE_FILE"
                echo "${P}: egress country was ${warp_cc}, server is ${server_cc}. Re-rolled to ${NEW_EP}, egress now ${got} (try ${try})"
                return 0
            fi
        done
        printf '%s %s\n' "$(( fails + 1 ))" "$now" > "$STATE_FILE"
        echo "${P}: egress country ${warp_cc} != server ${server_cc}, still ${got:-unknown} after 5 re-rolls. Backing off"
        return 0
    fi

    # The tunnel is down: rotate the endpoint and restart, as before. The backoff
    # above keeps restarts at least 3 minutes apart. Its drain marker stays until
    # a later run finds it healthy, so the restart does not put it back in the
    # route before it has proven itself.
    pick_endpoint
    sed -i "s/^Endpoint = .*/Endpoint = ${NEW_EP}/" "$CONF"
    systemctl restart "wg-quick@${IFACE}"
    printf '%s %s\n' "$(( fails + 1 ))" "$now" > "$STATE_FILE"
    echo "${P}: connection lost (hs age ${age}s, ping_ok ${ping_ok}). Rotated to ${NEW_EP}"
}

for i in "${!IFACES[@]}"; do
    check_iface "${IFACES[$i]}" "${STATES[$i]}"
done

# Rebuild the shared route when an interface was drained or came back, and heal
# it when the rule or the route went missing while a tunnel is up — without
# them Xray's marked traffic leaves from the server's real IP.
if [[ $changed -eq 0 ]]; then
    for i in "${IFACES[@]}"; do
        [[ -n "$(ip link show dev "$i" up 2>/dev/null)" ]] || continue
        ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$FWMARK") lookup ${TABLE}" || changed=1
        ip route show table "$TABLE" 2>/dev/null | grep -q '^default' || changed=1
        [[ $changed -eq 1 ]] && echo "WARP Watchdog: fwmark rule or route was missing, rebuilt"
        break
    done
fi
[[ $changed -eq 1 ]] && "$ROUTES"
exit 0
WDEOF
chmod 700 "$APP_DIR/watchdog.sh"

cat > /etc/systemd/system/warp-watchdog.service << EOF
[Unit]
Description=VPS-WARP Smart Watchdog
After=wg-quick@${WARP_IFACE}.service

[Service]
Type=oneshot
ExecStart=$APP_DIR/watchdog.sh
EOF

cat > /etc/systemd/system/warp-watchdog.timer << 'EOF'
[Unit]
Description=Run VPS-WARP Watchdog every 3 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min

[Install]
WantedBy=timers.target
EOF

chmod 644 /etc/systemd/system/warp-watchdog.service
chmod 644 /etc/systemd/system/warp-watchdog.timer

systemctl daemon-reload
systemctl enable warp-watchdog.timer --now &>/dev/null
done_ "$(t "watchdog_ok")"

# 10. CLI Dashboard
# Same two-part generation as the watchdog. The old single unquoted heredoc
# needed a backslash before every `$` across ~100 lines of shell, where one
# missed escape expands silently at install time and ships a broken CLI.
{
    printf '%s\n' '#!/bin/bash'
    printf 'RAW_URL=%q\n'        "$RAW_URL"
    printf 'VERSION_FILE=%q\n'   "$VERSION_FILE"
    printf 'STATE_DIR=%q\n'      "$STATE_DIR"
    printf 'EGRESS_OFF=%q\n'     "$EGRESS_OFF_FILE"
    printf 'APP_DIR=%q\n'        "$APP_DIR"
    printf 'IFACES=(%s)\n'       "$(printf '%q ' "${IFACES[@]}")"
    printf 'STATES=(%s)\n'       "$(printf '%q ' "${STATES[@]}")"
    printf 'FWMARK=%q\n'         "$WARP_FWMARK"
    printf 'WTABLE=%q\n'         "$WARP_TABLE"
    printf 'WMSS=%q\n'           "$WARP_MSS"
    printf 'DRAIN_DIR=%q\n'      "$DRAIN_DIR"
    printf 'RP_SYSCTL_FILE=%q\n' "$RP_SYSCTL_FILE"
    printf 'MP_SYSCTL_FILE=%q\n' "$MP_SYSCTL_FILE"
} > /usr/local/bin/vps-warp

cat >> /usr/local/bin/vps-warp << 'CLIEOF'
if [[ $EUID -ne 0 ]]; then
    echo -e "\e[31m✖ Error:\e[0m This command must be run as root or with sudo."
    exit 1
fi
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
C_RST="\e[0m"; C_BLD="\e[1m"; C_CYN="\e[36m"; C_GRN="\e[32m"; C_RED="\e[31m"; C_GRY="\e[90m"; C_YLW="\e[33m"

format_bytes() {
    local b=$1
    if [[ -z "$b" || "$b" == "0" ]]; then echo "0 KB"; return; fi
    if   [[ $b -lt 1048576 ]];    then echo "$((b / 1024)) KB"
    elif [[ $b -lt 1073741824 ]]; then echo "$((b / 1048576)) MB"
    else echo "$(awk "BEGIN {printf \"%.1f\", $b/1073741824}") GB"
    fi
}

random_endpoint() {
    local subnets=("188.114.96" "188.114.97") ports=(2408 500 4500 1701)
    echo "${subnets[RANDOM % ${#subnets[@]}]}.$(( RANDOM % 254 + 1 )):${ports[RANDOM % ${#ports[@]}]}"
}

# Two-letter country Cloudflare assigns to the source of this request; extra
# curl arguments pick the path. Empty on any failure.
cf_country() {
    curl -4 -s -m 5 "$@" https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1 == "loc" { print $2; exit }'
}

# The interfaces a command acts on: all of them, or the one named (must be ours).
targets() {
    local i
    if [[ -z "$1" ]]; then printf '%s\n' "${IFACES[@]}"; return; fi
    for i in "${IFACES[@]}"; do [[ "$i" == "$1" ]] && { echo "$i"; return; }; done
    echo -e "  ${C_RED}✖ Error:${C_RST} unknown interface '$1' (have: ${IFACES[*]})" >&2
}

function show_status {
    local version server_cc i n=${#IFACES[@]} lines=()
    local c_stat t_stat tunnel_ip endpoint raw_stats rx_fmt tx_fmt hs_ts c_hs t_hs warp_cc c_geo t_geo
    local c_rule t_rule hops rp_all rp_if rp_eff c_rp t_rp

    # `clear` comes after the probes below (the country check can take a few
    # seconds), so the previous screen stays up instead of a blank one.
    version=$(cat "$VERSION_FILE" 2>/dev/null || echo "?")
    server_cc=$(cf_country)

    for i in "${IFACES[@]}"; do
        if systemctl is-active --quiet "wg-quick@${i}"; then
            c_stat="${C_GRN}"; t_stat="● ACTIVE"
            if [[ $n -gt 1 && -f "${DRAIN_DIR}/${i}" ]]; then
                c_stat="${C_YLW}"; t_stat="● ACTIVE, out of the route (the watchdog found it dead)"
            fi
        else
            c_stat="${C_RED}"; t_stat="○ INACTIVE"
        fi

        tunnel_ip=$(ip -4 addr show "$i" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        endpoint=$(grep "^Endpoint" "/etc/wireguard/${i}.conf" 2>/dev/null | awk '{print $3}')

        raw_stats=$(wg show "$i" transfer 2>/dev/null | head -1)
        rx_fmt=$(format_bytes "$(awk '{print $2}' <<< "$raw_stats")")
        tx_fmt=$(format_bytes "$(awk '{print $3}' <<< "$raw_stats")")

        hs_ts=$(wg show "$i" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$hs_ts" && "$hs_ts" -gt 0 ]]; then
            c_hs="${C_GRN}"; t_hs="$(( $(date +%s) - hs_ts ))s ago"
        else
            c_hs="${C_RED}"; t_hs="No connection"
        fi

        # Egress country vs the server's own, as Cloudflare sees both. A mismatch
        # is what the watchdog re-rolls; `vps-warp rotate` re-rolls it by hand.
        # With the check off (--no-egress-check) the line is informational only.
        warp_cc=$(cf_country --interface "$i")
        if [[ -z "$server_cc" || -z "$warp_cc" ]]; then
            c_geo="${C_GRY}"; t_geo="${warp_cc:-?} (server ${server_cc:-?})"
        elif [[ "$warp_cc" == "$server_cc" ]]; then
            c_geo="${C_GRN}"; t_geo="${warp_cc} (matches the server)"
        elif [[ -f "$EGRESS_OFF" ]]; then
            c_geo="${C_GRY}"; t_geo="${warp_cc} — server is ${server_cc}"
        else
            c_geo="${C_YLW}"; t_geo="${warp_cc} — server is ${server_cc}, the watchdog will re-roll"
        fi
        [[ -f "$EGRESS_OFF" ]] && t_geo+=", check off"

        [[ $n -gt 1 ]] && lines+=("  ${C_BLD}${i}${C_RST}")
        lines+=("   ${C_GRY}Status:${C_RST}       ${c_stat}${t_stat}${C_RST}")
        lines+=("   ${C_GRY}Local IP:${C_RST}     ${C_CYN}${tunnel_ip:-"--"}${C_RST}")
        lines+=("   ${C_GRY}Cloudflare:${C_RST}   ${C_CYN}${endpoint:-"--"}${C_RST}")
        lines+=("   ${C_GRY}Egress:${C_RST}       ${c_geo}${t_geo}${C_RST}")
        lines+=("   ${C_GRY}Handshake:${C_RST}    ${c_hs}${t_hs}${C_RST}")
        lines+=("   ${C_GRY}Traffic:${C_RST}      ${C_YLW}↓ ${rx_fmt}${C_RST}  ${C_GRY}|${C_RST}  ${C_YLW}↑ ${tx_fmt}${C_RST}")
        [[ $n -gt 1 ]] && lines+=("")
    done

    # Surface the routing state: if the ip rule or the route is gone, Xray's
    # marked packets fall back to the default route and everything "works" from
    # the wrong IP. With several accounts the line lists the interfaces the
    # route currently spreads connections over.
    if ! ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$FWMARK") lookup ${WTABLE}"; then
        c_rule="${C_RED}"; t_rule="MISSING (fwmark ${FWMARK} → table ${WTABLE})"
    elif ! ip route show table "$WTABLE" 2>/dev/null | grep -q '^default'; then
        c_rule="${C_RED}"; t_rule="NO ROUTE in table ${WTABLE}"
    else
        hops=$(ip route show table "$WTABLE" 2>/dev/null | grep -oP '\bdev \K\S+' | paste -sd, - | sed 's/,/, /g')
        c_rule="${C_GRN}"; t_rule="ok (fwmark ${FWMARK} → table ${WTABLE}$([[ $n -gt 1 ]] && echo ": ${hops}"))"
    fi

    # Kernel uses max(conf.all, conf.<iface>); reporting either one alone would
    # be misleading, so compute the value the kernel actually enforces on each
    # interface and show the worst: strict anywhere, else loose anywhere, else off.
    rp_all=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 0)
    rp_eff=0
    for i in "${IFACES[@]}"; do
        rp_if=$(cat "/proc/sys/net/ipv4/conf/${i}/rp_filter" 2>/dev/null || echo 0)
        rp_if=$(( rp_all > rp_if ? rp_all : rp_if ))
        if [[ $rp_if -eq 1 ]]; then rp_eff=1; break; fi
        [[ $rp_if -eq 2 ]] && rp_eff=2
    done
    if [[ $rp_eff -eq 1 ]]; then
        c_rp="${C_RED}"; t_rp="STRICT (=1) — return traffic will be dropped"
    else
        c_rp="${C_GRN}"; t_rp="$([[ $rp_eff -eq 0 ]] && echo "off (=0)" || echo "loose (=2)")"
    fi

    clear
    echo -e "\n  ${C_BLD}⚡ VPS-WARP STATUS${C_RST} ${C_GRY}v${version}$([[ $n -gt 1 ]] && echo ", ${n} accounts")${C_RST}"
    echo -e "  ${C_GRY}───────────────────────────────────${C_RST}\n"
    for i in "${lines[@]}"; do echo -e "$i"; done
    echo -e "   ${C_GRY}Routing:${C_RST}      ${c_rule}${t_rule}${C_RST}"
    echo -e "   ${C_GRY}rp_filter:${C_RST}    ${c_rp}${t_rp}${C_RST}"
    echo -e "\n  ${C_GRY}───────────────────────────────────${C_RST}"
    echo -e "   ${C_GRY}Commands:${C_RST} start | stop | restart | rotate | log | update | uninstall\n"
}

# Force a new Cloudflare endpoint, i.e. a new draw of the egress machine, for
# every account or the one named. The local port stays: picked once at install,
# it makes the endpoint the key to the exit (same endpoint = same exit).
# `restart` deliberately does NOT rotate — keeping a working endpoint across
# restarts is usually what you want.
function rotate_endpoint {
    local i ep pub conf k
    local -a list
    mapfile -t list < <(targets "$1")
    [[ ${#list[@]} -gt 0 ]] || exit 1
    for i in "${list[@]}"; do
        conf="/etc/wireguard/${i}.conf"
        ep=$(random_endpoint)
        pub=$(wg show "$i" peers 2>/dev/null | head -1)
        if [[ -n "$pub" ]]; then
            # Tunnel is up: swap the endpoint live (drop and re-add the peer)
            # instead of restarting, so the route and the fwmark rule never go
            # away (see the watchdog).
            wg set "$i" peer "$pub" remove 2>/dev/null
            wg set "$i" peer "$pub" endpoint "$ep" allowed-ips 0.0.0.0/0 persistent-keepalive 15
        fi
        sed -i "s/^Endpoint = .*/Endpoint = ${ep}/" "$conf" || {
            echo -e "  ${C_RED}✖ Error:${C_RST} cannot write $conf"; exit 1; }
        [[ -n "$pub" ]] || systemctl restart "wg-quick@${i}"
        # A manual rotation means the operator is intervening; clear the backoff
        # so the watchdog isn't still sitting in a 30-minute cooldown afterwards.
        for k in "${!IFACES[@]}"; do [[ "${IFACES[$k]}" == "$i" ]] && rm -f "${STATES[$k]}"; done
        echo -e "  ${C_GRN}✔${C_RST} ${i}: rotated to ${ep}"
    done
    sleep 2
    show_status
}

function uninstall_self {
    local i
    echo -e "\n  ${C_YLW}⚠${C_RST} This removes the tunnel, watchdog, CLI and all VPS-WARP state."
    read -r -p "  Type 'yes' to confirm: " reply
    [[ "$reply" == "yes" ]] || { echo -e "  ${C_GRY}Aborted.${C_RST}\n"; exit 0; }

    for i in "${IFACES[@]}"; do systemctl disable --now "wg-quick@${i}" &>/dev/null; done
    systemctl disable --now warp-watchdog.timer warp-watchdog.service &>/dev/null
    rm -f /etc/systemd/system/warp-watchdog.service /etc/systemd/system/warp-watchdog.timer
    systemctl daemon-reload

    # Belt and braces: if an interface ever died without its hooks running, the
    # ip rule, the route and the mangle clamp survive and quietly misroute later
    # traffic.
    while ip rule del fwmark "$FWMARK" table "$WTABLE" 2>/dev/null; do :; done
    ip route flush table "$WTABLE" 2>/dev/null
    for i in "${IFACES[@]}"; do
        iptables -t mangle -D POSTROUTING -o "$i" -p tcp -m tcp \
            --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WMSS" 2>/dev/null
        ip link del "$i" 2>/dev/null
        rm -f "/etc/wireguard/${i}.conf"
    done

    rm -f "$RP_SYSCTL_FILE"
    if [[ -f "$MP_SYSCTL_FILE" ]]; then
        rm -f "$MP_SYSCTL_FILE"
        sysctl -qw net.ipv4.fib_multipath_hash_policy=0
    fi
    sysctl --system &>/dev/null
    rm -rf "$APP_DIR" "$STATE_DIR" "$DRAIN_DIR" "${DRAIN_DIR}.lock"
    rm -f /usr/local/bin/wgcf
    echo -e "  ${C_GRN}✔${C_RST} VPS-WARP removed. The wireguard package was left installed.\n"
    rm -f /usr/local/bin/vps-warp
}

# Self-update: fetch the latest installer, compare versions, reinstall if newer.
# `vps-warp update --force` reinstalls even when versions match.
function update_self {
    local force="$1" tmp remote local_v newest rc
    echo -e "\n  ${C_CYN}▶${C_RST} ${C_BLD}Checking for updates...${C_RST}"
    tmp=$(mktemp) || { echo -e "  ${C_RED}✖ Error:${C_RST} mktemp failed"; exit 1; }
    # -f: fail on HTTP errors so we never run an error page as a script.
    curl -fsSL -m 30 "$RAW_URL" -o "$tmp" || { rm -f "$tmp"; echo -e "  ${C_RED}✖ Error:${C_RST} download failed"; exit 1; }

    remote=$(grep -m1 -oP '^SCRIPT_VERSION="\K[^"]+' "$tmp")
    [[ -z "$remote" ]] && { rm -f "$tmp"; echo -e "  ${C_RED}✖ Error:${C_RST} cannot read remote version"; exit 1; }
    local_v=$(cat "$VERSION_FILE" 2>/dev/null || echo "0")

    newest=$(printf '%s\n%s\n' "$local_v" "$remote" | sort -V | tail -1)
    if [[ "$force" != "--force" && "$remote" == "$local_v" ]]; then
        rm -f "$tmp"
        echo -e "  ${C_GRN}✔${C_RST} Already up to date (v${local_v})"
        exit 0
    fi
    if [[ "$force" != "--force" && "$newest" == "$local_v" ]]; then
        rm -f "$tmp"
        echo -e "  ${C_YLW}⚠${C_RST} Installed v${local_v} is newer than remote v${remote}; use --force to reinstall"
        exit 0
    fi

    echo -e "  ${C_GRN}✔${C_RST} Updating v${local_v} → v${remote}"
    chmod +x "$tmp"
    bash "$tmp"
    rc=$?
    rm -f "$tmp"
    exit $rc
}

case "$1" in
    start|stop|restart)
        mapfile -t list < <(targets "$2")
        [[ ${#list[@]} -gt 0 ]] || exit 1
        for i in "${list[@]}"; do systemctl "$1" "wg-quick@${i}"; done
        sleep 1; show_status ;;
    rotate)    rotate_endpoint "$2" ;;
    log)       journalctl -u warp-watchdog.service -f ;;
    update)    update_self "$2" ;;
    uninstall) uninstall_self ;;
    status|"") show_status ;;
    *)         echo "Usage: vps-warp {status|start|stop|restart|rotate|log|update|uninstall}"
               echo "       start, stop, restart and rotate take an interface name to act on one account (default: all)"
               exit 1 ;;
esac
CLIEOF
chmod 755 /usr/local/bin/vps-warp

# Record installed version and number of accounts so `vps-warp update` can
# compare against the remote and keep the accounts.
mkdir -p "$STATE_DIR"
printf '%s\n' "$SCRIPT_VERSION" > "$VERSION_FILE"
printf '%s\n' "$ACCOUNTS" > "$ACCOUNTS_FILE"

# Finish
echo -e "\n  🎉 ${C_GRN}${C_BLD}$(t "finish")${C_RST}"
echo -e "  📌 ${C_BLD}Xray / Remnawave Outbound IP:${C_RST} ${C_CYN}${WARP_LOCAL_IP}${C_RST} ${C_GRY}(use as 'sendThrough')${C_RST}"
echo -e "  📌 ${C_BLD}fwmark for sockopt.mark:${C_RST} ${C_CYN}${WARP_FWMARK}${C_RST} ${C_GRY}(routes into table ${WARP_TABLE})${C_RST}"
if [[ $ACCOUNTS -gt 1 ]]; then
    echo -e "  📌 ${C_BLD}WARP accounts:${C_RST} ${C_CYN}${ACCOUNTS}${C_RST} ${C_GRY}(${IFACES[*]}; only sockopt.mark spreads over them)${C_RST}"
fi
echo -e "  👉 $(t "help"): ${C_CYN}vps-warp${C_RST}\n"
