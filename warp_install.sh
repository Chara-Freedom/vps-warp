#!/bin/bash

# ==============================================================================
#  VPS-WARP PRO (Xray Edition) - Ultimate Production Installer (v3.4)
# ==============================================================================
#
#  Deliberately NOT using `set -euo pipefail`: the flow depends on many probes
#  failing quietly (`systemctl disable ... || true`, `command -v`, optional
#  cleanups). Errors that matter are handled explicitly via fail().
# ==============================================================================

APP_DIR="/opt/vps-warp"
SCRIPT_LANG="en"

# Bump on every release. Used by `vps-warp update` for version comparison.
SCRIPT_VERSION="3.4"

# Persistent state dir — NOT wiped by the cleanup step. Holds installed version,
# the wgcf working directory and the watchdog's backoff state.
STATE_DIR="/etc/vps-warp"
VERSION_FILE="${STATE_DIR}/version"
LICENSE_FILE="${STATE_DIR}/license"
WGCF_DIR="${STATE_DIR}/wgcf"
WATCHDOG_STATE="${STATE_DIR}/watchdog.state"

# Routing knobs. WARP_FWMARK must match what Xray marks its packets with
# (sockopt.mark), otherwise the ip rule below never matches and traffic
# silently leaves the box unencapsulated.
WARP_IFACE="warp"
WARP_FWMARK=255
WARP_TABLE=51820
WARP_MTU=1280
WARP_MSS=$((WARP_MTU - 40))

# Self-update source of truth. MUST point at YOUR repo — `vps-warp update`
# downloads and runs this as root.
RAW_URL="https://raw.githubusercontent.com/tagashi666/vps-warp/main/warp_install.sh"

# Used only if GitHub's /releases/latest redirect can't be resolved (blocked or
# rate-limited). Bump occasionally so the fallback path doesn't rot.
WGCF_FALLBACK_VERSION="v2.2.29"

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
            "wgcf_fallback") echo "Не удалось определить последнюю версию wgcf, используем запасную" ;;
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
            "start_err") echo "Не удалось поднять интерфейс. Смотрите: journalctl -u wg-quick@warp" ;;
            "handshake") echo "Ожидание ответа сети (Handshake)..." ;;
            "hs_ok") echo "Соединение установлено! Задержка:" ;;
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
            "wgcf_fallback") echo "Could not resolve latest wgcf version, using fallback" ;;
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
            "start_err") echo "Interface failed to come up. See: journalctl -u wg-quick@warp" ;;
            "handshake") echo "Waiting for network handshake..." ;;
            "hs_ok") echo "Connection established! Latency:" ;;
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

# --- Pre-flight Checks ---
[[ $EUID -ne 0 ]] && fail "$(t "root_req")"

# --- Start ---
select_language
print_logo

# Steps 7–9 (start/watchdog) rely on systemctl — warn upfront on non-systemd
# inits (Alpine, OpenRC Gentoo, …). `/run/systemd/system` exists only when
# systemd is the running init, so this catches more than `command -v systemctl`.
[[ -d /run/systemd/system ]] || warn "$(t "no_systemd")"

# 1. Cleanup
step "🗑️  $(t "clean")"
systemctl disable "wg-quick@${WARP_IFACE}" --now &>/dev/null || true
systemctl disable warp-watchdog.timer --now &>/dev/null || true
rm -rf /opt/warp-native /opt/vps-warp /etc/cron.d/warp-native /usr/local/bin/warp /etc/systemd/system/warp-watchdog.* &>/dev/null
systemctl daemon-reload
done_ "$(t "clean_ok")"

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
# Resolution fails behind a censoring transit or on GitHub rate limits. Falling
# back to a known-good tag beats hard-failing an otherwise fine install.
if [[ "$WGCF_VERSION" != v* ]]; then
    warn "$(t "wgcf_fallback") (${WGCF_FALLBACK_VERSION})"
    WGCF_VERSION="$WGCF_FALLBACK_VERSION"
fi
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
step "🛡️  $(t "reg")"
mkdir -p "$WGCF_DIR"
chmod 700 "$STATE_DIR" "$WGCF_DIR"
[[ -f "$HOME/wgcf-account.toml" && ! -f "$WGCF_DIR/wgcf-account.toml" ]] \
    && mv "$HOME/wgcf-account.toml" "$WGCF_DIR/wgcf-account.toml"
cd "$WGCF_DIR" || fail "Cannot enter $WGCF_DIR"

if [[ ! -f wgcf-account.toml ]]; then
    for _ in {1..3}; do
        timeout 40 bash -c 'yes | wgcf register' &>/dev/null && break
        sleep 3
    done
fi
# Distinguish "registration never succeeded" from "generate itself broke" — the
# original reported both as the same opaque message.
[[ -f wgcf-account.toml ]] || fail "$(t "reg_err")"
chmod 600 wgcf-account.toml
wgcf generate &>/dev/null || fail "Config generation failed (wgcf generate)."
done_ "$(t "reg_ok")"

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
CONF="wgcf-profile.conf"
[[ -f "$CONF" ]] || fail "$CONF not found in $WGCF_DIR"

# Strip wgcf's defaults so only our values remain
sed -i '/^DNS =/d'   "$CONF"
sed -i '/^MTU =/d'   "$CONF"
sed -i '/^Table =/d' "$CONF"

# Blackhole Fix: drop IPv6 entirely
sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "$CONF"
sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$CONF"
sed -i 's/,\s*::\/0//' "$CONF"
sed -i '/AllowedIPs = ::\/0/d' "$CONF"

# Inject routing into [Interface].
#
# Table = <number> makes wg-quick install routes into a dedicated table and skip
# its own policy rules, so the host's default route is untouched — only packets
# carrying fwmark $WARP_FWMARK (i.e. Xray's) are steered into the tunnel.
#
# Every PostUp deletes its own rule before adding it. Without that, a hard
# reboot or an OOM-killed wg-quick leaves the rule behind and the next start
# stacks a duplicate; after a few crash cycles `ip rule show` is a wall of
# identical entries and the mangle chain holds N copies of the clamp.
sed -i "/^\[Interface\]/a\\
MTU = ${WARP_MTU}\\
Table = ${WARP_TABLE}\\
PostUp = ip rule del fwmark ${WARP_FWMARK} table ${WARP_TABLE} 2>/dev/null || true\\
PostUp = ip rule add fwmark ${WARP_FWMARK} table ${WARP_TABLE} || true\\
PostDown = ip rule del fwmark ${WARP_FWMARK} table ${WARP_TABLE} 2>/dev/null || true\\
PostUp = iptables -t mangle -D POSTROUTING -o ${WARP_IFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WARP_MSS} 2>/dev/null || true\\
PostUp = iptables -t mangle -A POSTROUTING -o ${WARP_IFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WARP_MSS} || true\\
PostDown = iptables -t mangle -D POSTROUTING -o ${WARP_IFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WARP_MSS} 2>/dev/null || true\\
" "$CONF"

# Inject Keepalive into [Peer]
sed -i '/^\[Peer\]/a\
PersistentKeepalive = 15\
' "$CONF"

# Endpoint randomisation (TSPU/DPI evasion).
# Kept from the original on purpose: for anti-DPI what matters is endpoint
# entropy, not the lowest ICMP RTT — hence no scan_endpoints pass.
# $RANDOM instead of shuf: minimal/busybox images don't always ship shuf, and a
# silently-empty RAND_* would write a malformed Endpoint line.
CF_SUBNETS=("188.114.96" "188.114.97")
CF_PORTS=(2408 500 4500 1701)
RAND_SUBNET=${CF_SUBNETS[RANDOM % ${#CF_SUBNETS[@]}]}
RAND_HOST=$(( RANDOM % 254 + 1 ))
RAND_PORT=${CF_PORTS[RANDOM % ${#CF_PORTS[@]}]}
sed -i "s/^Endpoint = .*/Endpoint = ${RAND_SUBNET}.${RAND_HOST}:${RAND_PORT}/" "$CONF"

mkdir -p /etc/wireguard
install -m 600 "$CONF" "/etc/wireguard/${WARP_IFACE}.conf"
rm -f "$CONF"

# Must happen before the interface comes up: `default` is the template new
# interfaces inherit from, so $WARP_IFACE picks up the relaxed value at creation.
rp_status=""
relax_rp_filter
done_ "$(t "opt_ok")"
[[ -n "$rp_status" ]] && done_ "$rp_status"

WARP_LOCAL_IP=$(grep -oP '(?<=Address = )[0-9.]+' "/etc/wireguard/${WARP_IFACE}.conf" | head -1)

# 7. Start Services
step "🚀 $(t "start")"
systemctl enable "wg-quick@${WARP_IFACE}" &>/dev/null
if systemctl restart "wg-quick@${WARP_IFACE}" &>/dev/null; then
    done_ "$(t "start_ok")"
else
    # Previously this failure was swallowed and the run continued into the
    # handshake loop, which then blamed the network for a config error.
    fail "$(t "start_err")"
fi

# 8. Handshake Check
step "📡 $(t "handshake")"
hs_ok=0
for _ in {1..15}; do
    hs_ts=$(wg show "$WARP_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    if [[ -n "$hs_ts" && "$hs_ts" -gt 0 ]]; then
        age=$(( $(date +%s) - hs_ts ))
        done_ "$(t "hs_ok") ${age}s"
        hs_ok=1
        break
    fi
    sleep 1
done
[[ $hs_ok -eq 0 ]] && warn "Handshake timeout. Interface is up, but connection might be blocked."

# 9. Systemd Watchdog (Triple Ping + Rotation Backoff)
step "🤖 $(t "watchdog")"
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" # Security: blocks local privilege escalation via the script

# Two-part generation: a header of values injected with printf %q (safe quoting)
# followed by a *quoted* heredoc, so nothing in the body needs escaping.
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# Generated by the vps-warp installer — edits are lost on update.'
    printf 'IFACE=%q\n'      "$WARP_IFACE"
    printf 'FWMARK=%q\n'     "$WARP_FWMARK"
    printf 'STATE_FILE=%q\n' "$WATCHDOG_STATE"
    printf 'CONF=%q\n'       "/etc/wireguard/${WARP_IFACE}.conf"
} > "$APP_DIR/watchdog.sh"

cat >> "$APP_DIR/watchdog.sh" << 'WDEOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Silent by design when the operator stopped the tunnel on purpose.
systemctl is-active --quiet "wg-quick@${IFACE}" || exit 0
[[ -f "$CONF" ]] || { echo "WARP Watchdog: $CONF missing, nothing to do"; exit 1; }

# Default to 0 *before* the arithmetic. `wg show` prints nothing when the
# interface exists but has no peer yet, and $(( now -  )) is a syntax error,
# not a zero — so the old code aborted right here instead of treating it as
# "no handshake", which is exactly the state the watchdog exists to repair.
hs_ts=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
hs_ts=${hs_ts:-0}
now=$(date +%s)
age=$(( now - hs_ts ))

# Probe along the same path Xray uses: fwmark -> ip rule -> WARP table.
# busybox ping has no -m, so fall back to binding the interface directly.
if ping -V 2>&1 | grep -qi iputils; then
    PING_ARGS=(-m "$FWMARK")
else
    PING_ARGS=(-I "$IFACE")
fi

ping_ok=0
for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
    if ping "${PING_ARGS[@]}" -c 1 -W 2 "$ip" &>/dev/null; then
        ping_ok=1
        break
    fi
done

healthy=1
[[ "$hs_ts" -eq 0 || $age -gt 180 ]] && healthy=0
[[ $ping_ok -eq 0 ]] && healthy=0

# --- Rotation backoff ---
# When Cloudflare is blocked wholesale rather than at one endpoint, rotating
# cannot help, and a fixed 3-minute retry means restarting WireGuard 480 times
# a day — which is itself a signature worth flagging. Back off exponentially,
# capped at 30 min, and reset the moment the link recovers.
fails=0; last_rot=0
[[ -f "$STATE_FILE" ]] && read -r fails last_rot < "$STATE_FILE" 2>/dev/null
fails=${fails:-0}; last_rot=${last_rot:-0}

if [[ $healthy -eq 1 ]]; then
    [[ $fails -ne 0 ]] && printf '0 %s\n' "$last_rot" > "$STATE_FILE"
    exit 0
fi

exp=$(( fails > 4 ? 4 : fails ))
backoff=$(( 180 * (2 ** exp) ))
[[ $backoff -gt 1800 ]] && backoff=1800
if [[ $(( now - last_rot )) -lt $backoff ]]; then
    echo "WARP Watchdog: still down (fail #${fails}), next rotation in $(( backoff - (now - last_rot) ))s"
    exit 0
fi

SUBNETS=("188.114.96" "188.114.97")
PORTS=(2408 500 4500 1701)
RAND_SUBNET=${SUBNETS[RANDOM % ${#SUBNETS[@]}]}
RAND_HOST=$(( RANDOM % 254 + 1 ))
RAND_PORT=${PORTS[RANDOM % ${#PORTS[@]}]}

sed -i "s/^Endpoint = .*/Endpoint = ${RAND_SUBNET}.${RAND_HOST}:${RAND_PORT}/" "$CONF"
systemctl restart "wg-quick@${IFACE}"
printf '%s %s\n' "$(( fails + 1 ))" "$now" > "$STATE_FILE"
echo "WARP Watchdog: connection lost (hs age ${age}s, ping_ok ${ping_ok}). Rotated to ${RAND_SUBNET}.${RAND_HOST}:${RAND_PORT}"
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
    printf 'RAW_URL=%q\n'      "$RAW_URL"
    printf 'VERSION_FILE=%q\n' "$VERSION_FILE"
    printf 'STATE_DIR=%q\n'    "$STATE_DIR"
    printf 'APP_DIR=%q\n'      "$APP_DIR"
    printf 'IFACE=%q\n'        "$WARP_IFACE"
    printf 'FWMARK=%q\n'       "$WARP_FWMARK"
    printf 'WTABLE=%q\n'       "$WARP_TABLE"
    printf 'WMSS=%q\n'         "$WARP_MSS"
    printf 'CONF=%q\n'         "/etc/wireguard/${WARP_IFACE}.conf"
    printf 'RP_SYSCTL_FILE=%q\n' "$RP_SYSCTL_FILE"
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

function show_status {
    clear

    if systemctl is-active --quiet "wg-quick@${IFACE}"; then
        c_stat="${C_GRN}"; t_stat="● ACTIVE"
    else
        c_stat="${C_RED}"; t_stat="○ INACTIVE"
    fi

    tunnel_ip=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    endpoint=$(grep "^Endpoint" "$CONF" 2>/dev/null | awk '{print $3}')
    version=$(cat "$VERSION_FILE" 2>/dev/null || echo "?")

    raw_stats=$(wg show "$IFACE" transfer 2>/dev/null | head -1)
    rx_fmt=$(format_bytes "$(awk '{print $2}' <<< "$raw_stats")")
    tx_fmt=$(format_bytes "$(awk '{print $3}' <<< "$raw_stats")")

    hs_ts=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    if [[ -n "$hs_ts" && "$hs_ts" -gt 0 ]]; then
        c_hs="${C_GRN}"; t_hs="$(( $(date +%s) - hs_ts ))s ago"
    else
        c_hs="${C_RED}"; t_hs="No connection"
    fi

    # Surface the routing state: if the ip rule is gone, Xray's marked packets
    # fall back to the default route and everything "works" from the wrong IP.
    if ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$FWMARK") lookup ${WTABLE}"; then
        c_rule="${C_GRN}"; t_rule="ok (fwmark ${FWMARK} → table ${WTABLE})"
    else
        c_rule="${C_RED}"; t_rule="MISSING (fwmark ${FWMARK} → table ${WTABLE})"
    fi

    # Kernel uses max(conf.all, conf.<iface>); reporting either one alone would
    # be misleading, so compute the value the kernel actually enforces.
    rp_all=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 0)
    rp_if=$(cat "/proc/sys/net/ipv4/conf/${IFACE}/rp_filter" 2>/dev/null || echo 0)
    rp_eff=$(( rp_all > rp_if ? rp_all : rp_if ))
    if [[ $rp_eff -eq 1 ]]; then
        c_rp="${C_RED}"; t_rp="STRICT (=1) — return traffic will be dropped"
    else
        c_rp="${C_GRN}"; t_rp="$([[ $rp_eff -eq 0 ]] && echo "off (=0)" || echo "loose (=2)")"
    fi

    echo -e "\n  ${C_BLD}⚡ VPS-WARP STATUS${C_RST} ${C_GRY}v${version}${C_RST}"
    echo -e "  ${C_GRY}───────────────────────────────────${C_RST}\n"
    echo -e "   ${C_GRY}Status:${C_RST}       ${c_stat}${t_stat}${C_RST}"
    echo -e "   ${C_GRY}Local IP:${C_RST}     ${C_CYN}${tunnel_ip:-"--"}${C_RST}"
    echo -e "   ${C_GRY}Cloudflare:${C_RST}   ${C_CYN}${endpoint:-"--"}${C_RST}"
    echo -e "   ${C_GRY}Handshake:${C_RST}    ${c_hs}${t_hs}${C_RST}"
    echo -e "   ${C_GRY}Routing:${C_RST}      ${c_rule}${t_rule}${C_RST}"
    echo -e "   ${C_GRY}rp_filter:${C_RST}    ${c_rp}${t_rp}${C_RST}"
    echo -e "   ${C_GRY}Traffic:${C_RST}      ${C_YLW}↓ ${rx_fmt}${C_RST}  ${C_GRY}|${C_RST}  ${C_YLW}↑ ${tx_fmt}${C_RST}"
    echo -e "\n  ${C_GRY}───────────────────────────────────${C_RST}"
    echo -e "   ${C_GRY}Commands:${C_RST} start | stop | restart | rotate | log | update | uninstall\n"
}

# Force a new Cloudflare endpoint. `restart` deliberately does NOT do this —
# keeping a working endpoint across restarts is usually what you want.
function rotate_endpoint {
    local ep
    ep=$(random_endpoint)
    sed -i "s/^Endpoint = .*/Endpoint = ${ep}/" "$CONF" || {
        echo -e "  ${C_RED}✖ Error:${C_RST} cannot write $CONF"; exit 1; }
    systemctl restart "wg-quick@${IFACE}"
    # A manual rotation means the operator is intervening; clear the backoff so
    # the watchdog isn't still sitting in a 30-minute cooldown afterwards.
    rm -f "${STATE_DIR}/watchdog.state"
    echo -e "  ${C_GRN}✔${C_RST} Rotated to ${ep}"
    sleep 2
    show_status
}

function uninstall_self {
    echo -e "\n  ${C_YLW}⚠${C_RST} This removes the tunnel, watchdog, CLI and all VPS-WARP state."
    read -r -p "  Type 'yes' to confirm: " reply
    [[ "$reply" == "yes" ]] || { echo -e "  ${C_GRY}Aborted.${C_RST}\n"; exit 0; }

    systemctl disable --now "wg-quick@${IFACE}" &>/dev/null
    systemctl disable --now warp-watchdog.timer warp-watchdog.service &>/dev/null
    rm -f /etc/systemd/system/warp-watchdog.service /etc/systemd/system/warp-watchdog.timer
    systemctl daemon-reload

    # Belt and braces: if the interface ever died without PostDown running, the
    # ip rule and the mangle clamp survive and quietly misroute later traffic.
    ip rule del fwmark "$FWMARK" table "$WTABLE" 2>/dev/null
    iptables -t mangle -D POSTROUTING -o "$IFACE" -p tcp -m tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WMSS" 2>/dev/null
    ip link del "$IFACE" 2>/dev/null

    rm -f "$CONF" "$RP_SYSCTL_FILE"
    sysctl --system &>/dev/null
    rm -rf "$APP_DIR" "$STATE_DIR"
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
    start)     systemctl start   "wg-quick@${IFACE}"; sleep 1; show_status ;;
    stop)      systemctl stop    "wg-quick@${IFACE}"; sleep 1; show_status ;;
    restart)   systemctl restart "wg-quick@${IFACE}"; sleep 1; show_status ;;
    rotate)    rotate_endpoint ;;
    log)       journalctl -u warp-watchdog.service -f ;;
    update)    update_self "$2" ;;
    uninstall) uninstall_self ;;
    status|"") show_status ;;
    *)         echo "Usage: vps-warp {status|start|stop|restart|rotate|log|update|uninstall}"; exit 1 ;;
esac
CLIEOF
chmod 755 /usr/local/bin/vps-warp

# Record installed version so `vps-warp update` can compare against the remote.
mkdir -p "$STATE_DIR"
printf '%s\n' "$SCRIPT_VERSION" > "$VERSION_FILE"

# Finish
echo -e "\n  🎉 ${C_GRN}${C_BLD}$(t "finish")${C_RST}"
echo -e "  📌 ${C_BLD}Xray / Remnawave Outbound IP:${C_RST} ${C_CYN}${WARP_LOCAL_IP}${C_RST} ${C_GRY}(use as 'sendThrough')${C_RST}"
echo -e "  📌 ${C_BLD}fwmark for sockopt.mark:${C_RST} ${C_CYN}${WARP_FWMARK}${C_RST} ${C_GRY}(routes into table ${WARP_TABLE})${C_RST}"
echo -e "  👉 $(t "help"): ${C_CYN}vps-warp${C_RST}\n"
