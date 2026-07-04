#!/bin/bash

# ==============================================================================
#  VPS-WARP PRO (Xray Edition) - Ultimate Production Installer (v3.2)
# ==============================================================================
#  Base: v3.1 + distro-agnostic deps (PR #1)
#  Merged from PR #2 (cherry-picked, reviewed):
#    - wgcf download hygiene only: `-f` + tmp + `install` (NOT checksum
#      verification — that was same-source theater; see step 3 comment)
#    - Read prompts from /dev/tty (works under `curl ... | bash`)
#    - `vps-warp update` self-updater
#  Deliberately NOT taken from PR #2:
#    - scan_endpoints (ICMP-RTT probing): wrong metric for a UDP/anti-DPI
#      threat model, and 42 parallel pings hammer cheap VPS. Kept the
#      original subnet/host/port randomization instead.
#    - apt-only dependency install (regression vs. PR #1).
# ==============================================================================

APP_DIR="/opt/vps-warp"
SCRIPT_LANG="en"

# Bump on every release. Used by `vps-warp update` for version comparison.
SCRIPT_VERSION="3.3"

# Persistent state dir — NOT wiped by the cleanup step. Holds installed version.
STATE_DIR="/etc/vps-warp"
VERSION_FILE="${STATE_DIR}/version"
LICENSE_FILE="${STATE_DIR}/license"

# Self-update source of truth. MUST point at YOUR repo — `vps-warp update`
# downloads and runs this as root.
RAW_URL="https://raw.githubusercontent.com/tagashi666/vps-warp/main/warp_install.sh"

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
    echo -e "${C_GRY}  ──────────────────────────────────${C_RST}\n"
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
            "deps") echo "Установка зависимостей (WireGuard, iptables)..." ;;
            "deps_ok") echo "Зависимости установлены" ;;
            "deps_err") echo "Ошибка установки зависимостей" ;;
            "no_pm") echo "Не найден поддерживаемый пакетный менеджер (apt/dnf/yum/zypper/pacman/apk/emerge)" ;;
            "no_systemd") echo "systemd не обнаружен — автозапуск туннеля и watchdog работать не будут (нужен ручной запуск/другой init)" ;;
            "wgcf") echo "Загрузка ядра wgcf..." ;;
            "wgcf_ok") echo "Ядро установлено" ;;
            "reg") echo "Регистрация в сети Cloudflare..." ;;
            "reg_ok") echo "Профиль готов" ;;
            "plus_ask") echo "🔑 Введите ключ WARP+ (или нажмите Enter для бесплатной версии):" ;;
            "plus_keep_hint") echo "(Enter — оставить сохранённый ключ)" ;;
            "plus_apply") echo "Активация WARP+..." ;;
            "plus_ok") echo "Лицензия активирована!" ;;
            "plus_err") echo "Ошибка ключа, используем базовый тариф." ;;
            "opt") echo "Глубокая оптимизация Xray (MTU, OUTPUT Clamping, IPv4)..." ;;
            "opt_ok") echo "Сетевой стек настроен" ;;
            "start") echo "Запуск туннеля..." ;;
            "start_ok") echo "Интерфейс поднят" ;;
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
            "deps") echo "Installing dependencies (WireGuard, iptables)..." ;;
            "deps_ok") echo "Dependencies installed" ;;
            "deps_err") echo "Dependency installation failed" ;;
            "no_pm") echo "No supported package manager found (apt/dnf/yum/zypper/pacman/apk/emerge)" ;;
            "no_systemd") echo "systemd not detected — tunnel autostart and watchdog will not work (manual start / other init needed)" ;;
            "wgcf") echo "Downloading wgcf core..." ;;
            "wgcf_ok") echo "Core installed" ;;
            "reg") echo "Registering Cloudflare account..." ;;
            "reg_ok") echo "Profile ready" ;;
            "plus_ask") echo "🔑 Enter WARP+ key (or press Enter for free tier):" ;;
            "plus_keep_hint") echo "(Enter — keep the saved key)" ;;
            "plus_apply") echo "Activating WARP+..." ;;
            "plus_ok") echo "License activated!" ;;
            "plus_err") echo "Key error, using free tier." ;;
            "opt") echo "Deep Xray Optimization (MTU, OUTPUT Clamping, IPv4)..." ;;
            "opt_ok") echo "Network stack optimized" ;;
            "start") echo "Starting tunnel..." ;;
            "start_ok") echo "Interface is up" ;;
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
                curl)     echo "net-misc/curl" ;;
                wget)     echo "net-misc/wget" ;;
            esac ;;
        dnf|yum) # Fedora / RHEL family
            case "$cmd" in
                wg-quick) echo "wireguard-tools" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
            esac ;;
        pacman|zypper|apk) # Arch/Manjaro, openSUSE, Alpine (identical names)
            case "$cmd" in
                wg-quick) echo "wireguard-tools" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute2" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
            esac ;;
        *)       # apt-get (Debian / Ubuntu) — wireguard metapackage keeps the
                 # kernel-module fallback for older kernels, as the original did.
            case "$cmd" in
                wg-quick) echo "wireguard" ;;
                iptables) echo "iptables" ;;
                ip)       echo "iproute2" ;;
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
function install_deps() {
    local required=(wg-quick ip iptables curl wget)
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
systemctl disable wg-quick@warp --now &>/dev/null || true
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
LATEST_URL=$(curl -Ls -w "%{url_effective}" -o /dev/null "https://github.com/ViRb3/wgcf/releases/latest")
WGCF_VERSION=$(basename "$LATEST_URL")
[[ "$WGCF_VERSION" == v* ]] || fail "Could not resolve latest wgcf version"
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && WGCF_ARCH="arm64" || WGCF_ARCH="amd64"
WGCF_DL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}"

WGCF_TMP=$(mktemp) || fail "mktemp failed"
curl -fsSL "$WGCF_DL" -o "$WGCF_TMP" || { rm -f "$WGCF_TMP"; fail "Download failed"; }
install -m 0755 "$WGCF_TMP" /usr/local/bin/wgcf || { rm -f "$WGCF_TMP"; fail "Install failed"; }
rm -f "$WGCF_TMP"
done_ "$(t "wgcf_ok") (v${WGCF_VERSION#v})"

# 4. Registration (Protected from Rate Limits)
step "🛡️  $(t "reg")"
cd "$HOME" || exit
if [[ ! -f wgcf-account.toml ]]; then
    for _ in {1..3}; do
        timeout 40 bash -c 'yes | wgcf register' &>/dev/null && break
        sleep 3
    done
fi
wgcf generate &>/dev/null || fail "Config generation failed. Cloudflare might be blocking the IP temporarily."
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
    # Security: Санитизация ввода (оставляем только буквы, цифры и дефисы)
    WARP_LICENSE=$(echo "$WARP_LICENSE" | tr -cd 'a-zA-Z0-9-')
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

# Очищаем конфиг от дефолтного мусора wgcf
sed -i '/^DNS =/d' "$CONF"
sed -i '/^MTU =/d' "$CONF"
sed -i '/^Table =/d' "$CONF"

# Blackhole Fix: Удаляем IPv6 полностью
sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "$CONF"
sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$CONF"
sed -i 's/,\s*::\/0//' "$CONF"
sed -i '/AllowedIPs = ::\/0/d' "$CONF"

# Жестко инжектим правила В СЕКЦИЮ [Interface]
sed -i '/^\[Interface\]/a\
MTU = 1280\
Table = 51820\
PostUp = ip rule add fwmark 255 table 51820 || true\
PostDown = ip rule del fwmark 255 table 51820 || true\
PostUp = iptables -t mangle -A POSTROUTING -o warp -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true\
PostDown = iptables -t mangle -D POSTROUTING -o warp -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true\
' "$CONF"

# Жестко инжектим Keepalive В СЕКЦИЮ [Peer]
sed -i '/^\[Peer\]/a\
PersistentKeepalive = 15\
' "$CONF"

# Расширенная рандомизация (Обход ТСПУ/DPI)
# Оставлено из оригинала намеренно: для анти-DPI важна энтропия эндпоинта,
# а не минимальный ICMP-пинг. См. шапку файла (почему scan_endpoints не взят).
RAND_SUBNET=$(shuf -e "188.114.96" "188.114.97" -n 1)
RAND_HOST=$(shuf -i 1-254 -n 1)
RAND_PORT=$(shuf -e 2408 500 4500 1701 -n 1)
sed -i "s/^Endpoint = .*/Endpoint = ${RAND_SUBNET}.${RAND_HOST}:${RAND_PORT}/" "$CONF"

mkdir -p /etc/wireguard
mv "$CONF" /etc/wireguard/warp.conf
chmod 600 /etc/wireguard/warp.conf # Security: Защита приватного ключа WG
chmod 600 "$HOME/wgcf-account.toml" 2>/dev/null || true
done_ "$(t "opt_ok")"

WARP_LOCAL_IP=$(grep -oP '(?<=Address = )[0-9\.]+' /etc/wireguard/warp.conf | head -1)

# 7. Start Services
step "🚀 $(t "start")"
systemctl enable wg-quick@warp &>/dev/null
systemctl start wg-quick@warp &>/dev/null
done_ "$(t "start_ok")"

# 8. Handshake Check
step "📡 $(t "handshake")"
hs_ok=0
for _ in {1..15}; do
    hs_ts=$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2}')
    if [[ -n "$hs_ts" && "$hs_ts" -gt 0 ]]; then
        age=$(( $(date +%s) - hs_ts ))
        done_ "$(t "hs_ok") ${age}s"
        hs_ok=1
        break
    fi
    sleep 1
done
[[ $hs_ok -eq 0 ]] && warn "Handshake timeout. Interface is up, but connection might be blocked."

# 9. Systemd Watchdog (Triple Ping System + Fixed PATH)
step "🤖 $(t "watchdog")"
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" # Security: Защита от локального Privilege Escalation
cat > "$APP_DIR/watchdog.sh" << 'EOF'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if ! systemctl is-active --quiet wg-quick@warp; then exit 0; fi

hs_ts=$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2}')
now=$(date +%s)
age=$(( now - hs_ts ))

ping_ok=0
for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
    # Пингуем через маркировку пакетов (так же, как ходит Xray)
    if ping -m 255 -c 1 -W 2 $ip &>/dev/null; then
        ping_ok=1
        break
    fi
done

if [[ -z "$hs_ts" || "$hs_ts" -eq 0 || $age -gt 180 ]] || [[ $ping_ok -eq 0 ]]; then
    RAND_SUBNET=$(shuf -e "188.114.96" "188.114.97" -n 1)
    RAND_HOST=$(shuf -i 1-254 -n 1)
    RAND_PORT=$(shuf -e 2408 500 4500 1701 -n 1)
    sed -i "s/^Endpoint = .*/Endpoint = ${RAND_SUBNET}.${RAND_HOST}:${RAND_PORT}/" /etc/wireguard/warp.conf
    systemctl restart wg-quick@warp
    echo "WARP Watchdog: Connection lost. Rotated to ${RAND_SUBNET}.${RAND_HOST}:${RAND_PORT}"
fi
EOF
chmod 700 "$APP_DIR/watchdog.sh"

cat > /etc/systemd/system/warp-watchdog.service << EOF
[Unit]
Description=VPS-WARP Smart Watchdog

[Service]
Type=oneshot
ExecStart=$APP_DIR/watchdog.sh
EOF

cat > /etc/systemd/system/warp-watchdog.timer << EOF
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

# 10. CLI Dashboard (Flat Design + Traffic Stats)
cat > /usr/local/bin/vps-warp <<EOF
#!/bin/bash
if [[ \$EUID -ne 0 ]]; then
    echo -e "\e[31m✖ Error:\e[0m This command must be run as root or with sudo."
    exit 1
fi
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
C_RST="\e[0m"; C_BLD="\e[1m"; C_CYN="\e[36m"; C_GRN="\e[32m"; C_RED="\e[31m"; C_GRY="\e[90m"; C_YLW="\e[33m"

# Injected from installer so the updater always targets the right repo/file.
RAW_URL="${RAW_URL}"
VERSION_FILE="${VERSION_FILE}"

format_bytes() {
    local b=\$1
    if [[ -z "\$b" || "\$b" == "0" ]]; then echo "0 KB"; return; fi
    if [[ \$b -lt 1048576 ]]; then echo "\$((b / 1024)) KB"
    elif [[ \$b -lt 1073741824 ]]; then echo "\$((b / 1048576)) MB"
    else echo "\$(awk "BEGIN {printf \\"%.1f\\", \$b/1073741824}") GB"
    fi
}

function show_status {
    clear

    if systemctl is-active --quiet wg-quick@warp; then
        c_stat="\${C_GRN}"
        t_stat="● ACTIVE"
    else
        c_stat="\${C_RED}"
        t_stat="○ INACTIVE"
    fi

    tunnel_ip=\$(ip -4 addr show warp 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    endpoint=\$(grep "^Endpoint" /etc/wireguard/warp.conf 2>/dev/null | awk '{print \$3}')

    raw_stats=\$(wg show warp transfer 2>/dev/null | awk '{print \$2, \$3}')
    rx_bytes=\$(echo "\$raw_stats" | awk '{print \$1}')
    tx_bytes=\$(echo "\$raw_stats" | awk '{print \$2}')
    rx_fmt=\$(format_bytes "\$rx_bytes")
    tx_fmt=\$(format_bytes "\$tx_bytes")

    hs_ts=\$(wg show warp latest-handshakes 2>/dev/null | awk '{print \$2}')
    if [[ -n "\$hs_ts" && "\$hs_ts" -gt 0 ]]; then
        c_hs="\${C_GRN}"
        t_hs="\$(( \$(date +%s) - hs_ts ))s ago"
    else
        c_hs="\${C_RED}"
        t_hs="No connection"
    fi

    echo -e "\n  \${C_BLD}⚡ VPS-WARP STATUS\${C_RST}"
    echo -e "  \${C_GRY}───────────────────────────────────\${C_RST}\n"

    echo -e "   \${C_GRY}Status:\${C_RST}       \${c_stat}\${t_stat}\${C_RST}"
    echo -e "   \${C_GRY}Local IP:\${C_RST}     \${C_CYN}\${tunnel_ip:---}\${C_RST}"
    echo -e "   \${C_GRY}Cloudflare:\${C_RST}   \${C_CYN}\${endpoint:---}\${C_RST}"
    echo -e "   \${C_GRY}Handshake:\${C_RST}    \${c_hs}\${t_hs}\${C_RST}"
    echo -e "   \${C_GRY}Traffic:\${C_RST}      \${C_YLW}↓ \${rx_fmt}\${C_RST}  \${C_GRY}|\${C_RST}  \${C_YLW}↑ \${tx_fmt}\${C_RST}"

    echo -e "\n  \${C_GRY}───────────────────────────────────\${C_RST}"
    echo -e "   \${C_GRY}Commands:\${C_RST} vps-warp \${C_BLD}start\${C_RST} | \${C_BLD}stop\${C_RST} | \${C_BLD}restart\${C_RST} | \${C_BLD}log\${C_RST} | \${C_BLD}update\${C_RST}\n"
}

# Self-update: fetch the latest installer, compare versions, reinstall if newer.
# \`vps-warp update --force\` reinstalls even when versions match.
function update_self {
    local force="\$1" tmp remote local_v newest
    echo -e "\n  \${C_CYN}▶\${C_RST} \${C_BLD}Checking for updates...\${C_RST}"
    tmp=\$(mktemp) || { echo -e "  \${C_RED}✖ Error:\${C_RST} mktemp failed"; exit 1; }
    # -f: fail on HTTP errors so we never run an error page as a script.
    curl -fsSL "\$RAW_URL" -o "\$tmp" || { rm -f "\$tmp"; echo -e "  \${C_RED}✖ Error:\${C_RST} download failed"; exit 1; }

    remote=\$(grep -m1 -oP '^SCRIPT_VERSION="\K[^"]+' "\$tmp")
    [[ -z "\$remote" ]] && { rm -f "\$tmp"; echo -e "  \${C_RED}✖ Error:\${C_RST} cannot read remote version"; exit 1; }
    local_v=\$(cat "\$VERSION_FILE" 2>/dev/null || echo "0")

    newest=\$(printf '%s\n%s\n' "\$local_v" "\$remote" | sort -V | tail -1)
    if [[ "\$force" != "--force" && "\$remote" == "\$local_v" ]]; then
        rm -f "\$tmp"
        echo -e "  \${C_GRN}✔\${C_RST} Already up to date (v\${local_v})"
        exit 0
    fi
    if [[ "\$force" != "--force" && "\$newest" == "\$local_v" ]]; then
        rm -f "\$tmp"
        echo -e "  \${C_YLW}⚠\${C_RST} Installed v\${local_v} is newer than remote v\${remote}; use --force to reinstall"
        exit 0
    fi

    echo -e "  \${C_GRN}✔\${C_RST} Updating v\${local_v} → v\${remote}"
    chmod +x "\$tmp"
    bash "\$tmp"
    local rc=\$?
    rm -f "\$tmp"
    exit \$rc
}

case "\$1" in
    start)   systemctl start wg-quick@warp; show_status ;;
    stop)    systemctl stop wg-quick@warp; show_status ;;
    restart) systemctl restart wg-quick@warp; show_status ;;
    log)     journalctl -u warp-watchdog.service -f ;;
    update)  update_self "\$2" ;;
    *)       show_status ;;
esac
EOF
chmod +x /usr/local/bin/vps-warp

# Record installed version so `vps-warp update` can compare against the remote.
mkdir -p "$STATE_DIR"
printf '%s\n' "$SCRIPT_VERSION" > "$VERSION_FILE"

# Finish
echo -e "\n  🎉 ${C_GRN}${C_BLD}$(t "finish")${C_RST}"
echo -e "  📌 ${C_BLD}Xray / Remnawave Outbound IP:${C_RST} ${C_CYN}${WARP_LOCAL_IP}${C_RST} ${C_GRY}(use as 'sendThrough')${C_RST}"
echo -e "  👉 $(t "help"): ${C_CYN}vps-warp${C_RST}\n"
