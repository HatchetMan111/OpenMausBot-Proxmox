#!/usr/bin/env bash
# =============================================================================
#  🐭 Proxmox OpenMausBot – One-Click Installer
#  https://github.com/HatchetMan111/proxmox-openmausbot
#
#  Installiert OpenMausBot (https://github.com/milind-soni/OpenMausBot) als
#  unprivilegierten LXC-Container mit systemd-Service + Caddy-Reverse-Proxy.
#
#  Installation (auf Proxmox VE als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/proxmox-openmausbot/main/install/openmausbot.sh)"
#
#  Mit Optionen:
#    .../install/openmausbot.sh --id 220 --memory 4096 --ip 192.168.1.50/24
#
#  Pairing-Code für den Browser erzeugen:
#    .../install/openmausbot.sh --pair
#
#  Update / Deinstallieren / Status:
#    .../install/openmausbot.sh --update
#    .../install/openmausbot.sh --uninstall
#    .../install/openmausbot.sh --status
#
#  Debug (vollständiges bash -x-Log):
#    .../install/openmausbot.sh --debug
# =============================================================================
#
#  Architektur-Hinweis: Der OpenMausBot-Server bindet bewusst NUR 127.0.0.1
#  (Sicherheitsdesign des upstream: "Never expose that port directly").
#  Genau wie im offiziellen Docker-Setup liegt daher ein Caddy davor:
#
#      Browser ──HTTP──▶ Caddy :${WEB_PORT} ──▶ 127.0.0.1:${OMB_PORT}   (Web-UI, SSE)
#                                   └────▶ 127.0.0.1:${OMB_WEBHOOK_PORT} (/hooks/*)
#
#  Browser verbinden sich per Pairing-Code (`--pair`) – unauthentifizierte
#  Browser sehen nur die Pairing-Seite.

set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
APP_NAME="openmausbot"
OMB_VERSION="0.1.144"       # gepinnte Version (IDEMPOTENT); --version latest = immer neueste
OMB_ENGINES_DEFAULT="claude codex"   #claude/codex/grok (npm/x.ai-Installer), Login macht der Nutzer
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="openmausbot"
CT_STORAGE="local-lvm"
CT_ROOTFS=16                # GB (Node + Engines + Chrome-Libs; kein torch/docling)
CT_CORES=2
CT_MEMORY=3072              # MB
CT_SWAP=0
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_PASSWORD=""              # leer = automatisch generieren
CT_TEMPLATE=""
WEB_PORT=8080               # Caddy Reverse Proxy (von außen erreichbar)
OMB_PORT=8799               # OpenMausBot-Server (loopback only – upstream-Design)
OMB_WEBHOOK_PORT=8800       # Webhook-Receiver (loopback, via /hooks/* proxied)
OMB_DATA_DIR="/opt/openmausbot/data"
OMB_HOME="/opt/openmausbot"
INSTALL_ENGINES=""          # leer = OMB_ENGINES_DEFAULT; via --engines überschreibbar
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
PAIR_MODE=false
FORCE_RECREATE=false
ASSUME_YES=false
DEBUG=false
TMP_DIR=""
LOG_FILE="/tmp/openmausbot-installer-$(date +%Y%m%d-%H%M%S).log"

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup-Log + journalctl), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 15 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Service):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 25 /var/log/openmausbot-setup.log 2>/dev/null
            echo "--- journalctl -u openmausbot ---"
            journalctl -u openmausbot --no-pager 2>/dev/null | tail -n 25
            echo "--- journalctl -u caddy ---"
            journalctl -u caddy --no-pager 2>/dev/null | tail -n 10
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Diagnose:  pct exec $CT_ID -- runuser -u openmausbot -- openmausbot doctor"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace:  --debug  (z. B. $(basename "$0") --debug)"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)             CT_ID="$2"; shift 2 ;;
            --hostname)       CT_HOSTNAME="$2"; shift 2 ;;
            --storage)        CT_STORAGE="$2"; shift 2 ;;
            --rootfs)         CT_ROOTFS="$2"; shift 2 ;;
            --cores)          CT_CORES="$2"; shift 2 ;;
            --memory)         CT_MEMORY="$2"; shift 2 ;;
            --swap)           CT_SWAP="$2"; shift 2 ;;
            --bridge)         CT_BRIDGE="$2"; shift 2 ;;
            --ip)             CT_IP="$2"; shift 2 ;;
            --password)       CT_PASSWORD="$2"; shift 2 ;;
            --template)       CT_TEMPLATE="$2"; shift 2 ;;
            --version)        OMB_VERSION="$2"; shift 2 ;;
            --port)           WEB_PORT="$2"; shift 2 ;;
            --engines)        INSTALL_ENGINES="$2"; shift 2 ;;
            --update)         UPDATE=true; shift ;;
            --uninstall)      UNINSTALL=true; shift ;;
            --status)         STATUS_CHECK=true; shift ;;
            --pair)           PAIR_MODE=true; shift ;;
            --force-recreate) FORCE_RECREATE=true; shift ;;
            --yes|-y)         ASSUME_YES=true; shift ;;
            --debug)          DEBUG=true; shift ;;
            --help|-h)        usage; exit 0 ;;
            *)                die "Unbekanntes Argument: $1 (--help für Hilfe)" ;;
        esac
    done
    if $DEBUG; then
        set -x
        info "Debug-Modus aktiv (bash -x) – alles landet in $LOG_FILE"
    fi
    # Engine-Liste normalisieren (Default, falls nicht gesetzt)
    if [[ -z "$INSTALL_ENGINES" ]]; then
        INSTALL_ENGINES="$OMB_ENGINES_DEFAULT"
    fi
    validate_engines
}

validate_engines() {
    local eng
    for eng in $INSTALL_ENGINES; do
        case "$eng" in
            claude|codex|grok) ;;
            none) [[ "$INSTALL_ENGINES" == "none" ]] || die "--engines none darf nicht kombiniert werden" ;;
            *)    die "Unbekannte Engine '$eng' – erlaubt: claude, codex, grok, none" ;;
        esac
    done
}

usage() {
    cat <<'USAGE'
🐭  Proxmox OpenMausBot – One-Click Installer
   Installiert milind-soni/OpenMausBot (Self-hosted AI-Agent-Chat) als LXC.

Usage:
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/proxmox-openmausbot/main/install/openmausbot.sh)" [OPTIONS]

Options:
  --id NUM            Container-ID (Default: automatisch nächste freie ab 200)
  --hostname TEXT     Hostname (Default: openmausbot)
  --storage TEXT      Proxmox Storage (Default: local-lvm)
  --rootfs NUM        RootFS in GB (Default: 16)
  --cores NUM         CPU-Kerne (Default: 2)
  --memory NUM        RAM in MB (Default: 3072)
  --swap NUM          Swap in MB (Default: 0)
  --bridge TEXT       Netzwerk-Bridge (Default: vmbr0)
  --ip ADDR           Statische IP (z. B. 192.168.1.50/24) oder "dhcp" (Default: dhcp)
  --password TEXT     Root-Passwort (Default: automatisch generiert)
  --template TEXT     CT-Template (Default: neuestes debian-12-standard via pveam)
  --version VER       OpenMausBot-Version pinnen (Default: 0.1.144, "latest" = immer neueste)
  --port NUM          Externer Web-UI-Port (Caddy, Default: 8080)
  --engines LIST      Engine-CLIs: "claude codex grok", "claude", ... oder "none"
                      (Default: "claude codex" – Login danach per Web-UI oder --pair-Hinweis)
  --update            OpenMausBot im bestehenden Container aktualisieren
  --uninstall         Container vollständig entfernen
  --status            Service-Status anzeigen
  --pair              Pairing-Code für den Browser erzeugen (einmalig, 24 h gültig)
  --force-recreate    Bei bestehendem Container: löschen und neu installieren
  --yes, -y           Rückfragen automatisch mit "ja" beantworten
  --debug             Vollständiges bash -x-Log ausgeben
  --help              Diese Hilfe

Ports im Container:  8080 = Web-UI (Caddy, extern) · 8799 = Server (nur loopback!)
                     8800 = Webhooks (nur loopback, via /hooks/* proxied)

Examples:
  # Standard-Installation (nächste freie ID ab 200):
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/proxmox-openmausbot/main/install/openmausbot.sh)"

  # Mit eigener ID, statischer IP und anderem Web-Port:
  ... --id 220 --ip 192.168.1.51/24 --port 8081

  # Pairing-Code für den Browser:
  ... --pair

  # Update / Status / Deinstallation:
  ... --update
  ... --status
  ... --uninstall --yes
USAGE
}

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
# Nächste freie Container-ID finden (ID-Vorgabe wird bei Belegung erhöht)
find_free_id() {
    [[ -z "$CT_ID" ]] && CT_ID="$ID_SCAN_START"
    local orig_id="$CT_ID"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx -- "$CT_ID"; do
        CT_ID=$((CT_ID + 1))
    done
    # if statt [[ ]] && – sonst gibt die Funktion 1 zurück, wenn die ID frei war
    if [[ "$CT_ID" != "$orig_id" ]]; then
        info "Container $orig_id ist belegt – verwende stattdessen ID $CT_ID"
    fi
    return 0
}

# Existiert bereits ein Container mit dem Ziel-Hostnamen? → dessen ID
find_existing_ct() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" \
        'NR>1 { for (i=2; i<=NF; i++) if ($i==h) { print $1; exit } }'
}

ct_exists() {
    pct list 2>/dev/null | awk '{print $1}' | grep -qx -- "$1"
}

confirm() {
    $ASSUME_YES && return 0
    local reply
    read -r -p "$1 [y/N]: " reply || return 1
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Container-IP ermitteln (dhcp → aus Container lesen, sonst statischer Wert)
get_ct_ip() {
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}'
    return 0
}

# ── Voraussetzungen prüfen ─────────────────────────────────────────────────
check_prerequisites() {
    header "Prüfe Voraussetzungen"

    [[ $EUID -ne 0 ]] && die "Bitte als root ausführen (sudo bash ...)"
    command -v pct &>/dev/null   || die "pct nicht gefunden – läuft dieses Script auf einem Proxmox VE Host?"

    # Template/Storage nur für Installations-Modi relevant (status/update/uninstall/pair nicht)
    if $UNINSTALL || $UPDATE || $STATUS_CHECK || $PAIR_MODE; then
        return 0
    fi

    command -v pveam &>/dev/null || die "pveam nicht gefunden – ist Proxmox VE korrekt installiert?"

    # Template automatisch finden/downloaden
    if [[ -z "$CT_TEMPLATE" ]]; then
        local t
        # sort -V: bei mehreren gecachten Versionen das neueste Template nehmen
        t=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | sort -V | tail -1 || true)
        if [[ -z "$t" ]]; then
            info "Lade Debian-12-Template herunter (einmalig)..."
            local tpl_name
            tpl_name=$(pveam available --section system 2>/dev/null \
                | grep -o "debian-12-standard_[^ ]*\.tar\.zst" | sort -V | tail -1 || true)
            [[ -z "$tpl_name" ]] && die "Kein Debian-12-Template gefunden.\n  Bitte prüfen: pveam update && pveam available --section system"
            pveam download local "$tpl_name" 2>&1 | tail -3
            t=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | head -1 || true)
            [[ -z "$t" ]] && die "Template-Download fehlgeschlagen.\n  Bitte manuell: pveam update && pveam download local $tpl_name"
        fi
        CT_TEMPLATE=$(basename "$(echo "$t" | awk '{print $1}')")
    fi
    ok "Template: $CT_TEMPLATE"

    # Statische IP grob validieren (nur Warnung)
    if [[ "$CT_IP" != "dhcp" && ! "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ && ! "$CT_IP" =~ ^(dhcp|dhcp6|auto|manual)$ ]]; then
        warn "CT_IP='$CT_IP' sieht nicht wie eine gültige IP/CIDR aus – pct create könnte fehlschlagen"
    fi

    if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || (( WEB_PORT < 1 || WEB_PORT > 65535 )); then
        die "Ungültiger --port: $WEB_PORT (1–65535)"
    fi
}

# ── Deinstallieren ─────────────────────────────────────────────────────────
do_uninstall() {
    local ct_id="$1"
    CT_ID="$ct_id"   # für die Fehlerkette (on_error) setzen
    header "Entferne Container $ct_id ($CT_HOSTNAME)"

    confirm "Container $ct_id inkl. aller OpenMausBot-Daten (Chats, Engine-Logins) wirklich löschen?" \
        || die "Abgebrochen (mit --yes überspringst du die Rückfrage)."

    pct stop "$ct_id" 2>/dev/null || true
    sleep 2
    pct destroy "$ct_id" --purge 2>/dev/null
    ok "Container $ct_id entfernt"
    exit 0
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    local ct_id="$1"
    CT_ID="$ct_id"   # für die Fehlerkette (on_error) setzen
    header "Status: Container $ct_id ($CT_HOSTNAME)"

    if ! ct_exists "$ct_id"; then
        warn "Container $ct_id existiert nicht"
        exit 0
    fi

    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    info "Container: $state"

    if [[ "$state" == *"running"* ]]; then
        if pct exec "$ct_id" -- systemctl is-active openmausbot &>/dev/null; then
            ok "Service: openmausbot läuft (aktiv)"
        else
            warn "Service: openmausbot läuft NICHT"
        fi
        if pct exec "$ct_id" -- systemctl is-active caddy &>/dev/null; then
            ok "Reverse-Proxy: caddy läuft (aktiv)"
        else
            warn "Reverse-Proxy: caddy läuft NICHT"
        fi

        local ct_ip
        ct_ip=$(get_ct_ip "$ct_id")
        if [[ -n "$ct_ip" ]]; then
            info "IP: $ct_ip"
            if command -v curl &>/dev/null; then
                # curl -w gibt bei Verbindungsfehler bereits '000' aus – kein '|| echo 000',
                # sonst entstehen Werte wie '000000' und der Check wird falsch-positiv.
                local code
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ct_ip}:${WEB_PORT}/" 2>/dev/null || true)
                if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
                    ok "Web-UI antwortet: http://${ct_ip}:${WEB_PORT} (HTTP $code)"
                    return 0
                fi
                warn "Web-UI antwortet nicht von außen (HTTP ${code:-000})"
            fi
        fi
        pct exec "$ct_id" -- systemctl status openmausbot --no-pager 2>/dev/null | head -15 || true
    fi
    exit 0
}

# ── Pairing-Code erzeugen (Browser-Login – Pflicht, auch lokal!) ───────────
do_pair() {
    local ct_id="$1"
    CT_ID="$ct_id"   # für die Fehlerkette (on_error) setzen
    header "🔑 Pairing-Code für $CT_HOSTNAME (Container $ct_id)"

    if ! pct exec "$ct_id" -- systemctl is-active openmausbot &>/dev/null; then
        die "Service 'openmausbot' läuft nicht.\n  Erst starten: pct start $ct_id\n  Logs: pct exec $ct_id -- journalctl -u openmausbot -e"
    fi

    local ct_ip public_url=""
    ct_ip=$(get_ct_ip "$ct_id")
    [[ -n "$ct_ip" ]] && public_url="http://${ct_ip}:${WEB_PORT}"

    info "Erzeuge Pairing-Code (einmalig nutzbar, 24 h gültig)..."
    echo ""
    # Fehlgeschlagener pct exec → ERR-Trap gibt die komplette Fehlerkette aus
    pct exec "$ct_id" -- env HOME="$OMB_HOME" OMB_DATA_DIR="$OMB_DATA_DIR" OMB_PORT="$OMB_PORT" \
        OMB_PUBLIC_URL="$public_url" \
        runuser -u openmausbot -- openmausbot pair --ttl 24h
    echo ""
    info "Code oben im Browser eingeben (Pairing-Seite) oder den Link direkt öffnen."
    info "Neuen Code erzeugen: dieses Script mit --pair"
    exit 0
}

# ── In-Container-Setup-Script erzeugen (idempotent) ────────────────────────
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# OpenMausBot In-Container-Setup (idempotent – safe für Update & Re-Run)
# Wird vom Installer via `pct push` + `pct exec` ausgeführt (als root).
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
[[ "${OMB_DEBUG:-0}" == "1" ]] && set -x
exec > >(tee /var/log/openmausbot-setup.log) 2>&1

OMB_VERSION="${OMB_VERSION:?OMB_VERSION nicht gesetzt}"
OMB_ENGINES_NPM="${OMB_ENGINES_NPM:-}"     # z. B. "@anthropic-ai/claude-code @openai/codex"
OMB_INSTALL_GROK="${OMB_INSTALL_GROK:-0}"  # 1 = x.ai Grok CLI zusätzlich installieren
OMB_HOME="${OMB_HOME:?OMB_HOME nicht gesetzt}"
OMB_DATA_DIR="${OMB_DATA_DIR:?OMB_DATA_DIR nicht gesetzt}"
OMB_PORT="${OMB_PORT:?OMB_PORT nicht gesetzt}"
OMB_WEBHOOK_PORT="${OMB_WEBHOOK_PORT:?OMB_WEBHOOK_PORT nicht gesetzt}"
OMB_PUBLIC_URL="${OMB_PUBLIC_URL:-}"
OMB_WEB_PORT="${OMB_WEB_PORT:?OMB_WEB_PORT nicht gesetzt}"

NPM_SPEC="openmausbot@${OMB_VERSION}"
[[ "$OMB_VERSION" == "latest" ]] && NPM_SPEC="openmausbot@latest"

step() { echo -e "\n━━━ [setup] $* ━━━"; }

step "1/7 apt: Basispakete + Browser-/Chrome-Laufzeitbibliotheken (wie upstream Dockerfile) + Caddy"
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl git caddy \
    libxcb-shm0 libx11-xcb1 libx11-6 libxcb1 libxext6 libxrandr2 \
    libxcomposite1 libxcursor1 libxdamage1 libxfixes3 libxi6 libgtk-3-0 \
    libpangocairo-1.0-0 libpango-1.0-0 libatk1.0-0 libcairo-gobject2 \
    libcairo2 libgdk-pixbuf-2.0-0 libxrender1 libasound2 libfreetype6 \
    libfontconfig1 libdbus-1-3 libnss3 libnss3-tools libnspr4 \
    libatk-bridge2.0-0 libdrm2 libxkbcommon0 libatspi2.0-0 libcups2 \
    libxshmfence1 libgbm1 \
    fonts-noto-color-emoji fonts-noto-cjk fonts-freefont-ttf

step "2/7 Node.js 24 (OpenMausBot benötigt Node 24+)"
if ! node --version 2>/dev/null | grep -q '^v24\.'; then
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - 2>&1 | tail -3
    apt-get install -y nodejs
fi
node --version

step "3/7 Systemuser 'openmausbot' (nicht-root Betrieb wie beim upstream Docker-Image)"
if ! id -u openmausbot &>/dev/null; then
    useradd -r -m -d "$OMB_HOME" -s /usr/sbin/nologin openmausbot
fi
mkdir -p "$OMB_DATA_DIR"

step "4/7 npm: openmausbot ${OMB_VERSION} global installieren"
if ! npm install -g --no-audit --no-fund "$NPM_SPEC" 2>/var/log/openmausbot-npm.log; then
    echo "npm install ${NPM_SPEC} fehlgeschlagen:"; tail -n 40 /var/log/openmausbot-npm.log; exit 1
fi
openmausbot --version 2>/dev/null || true

if [[ -n "$OMB_ENGINES_NPM" ]]; then
    step "5/7 npm: Engine-CLIs installieren (${OMB_ENGINES_NPM})"
    if ! npm install -g --no-audit --no-fund $OMB_ENGINES_NPM 2>>/var/log/openmausbot-npm.log; then
        echo "npm install der Engine-CLIs fehlgeschlagen:"; tail -n 40 /var/log/openmausbot-npm.log; exit 1
    fi
else
    step "5/7 npm: keine Engine-CLIs gewählt (--engines none) – später per Web-UI/Engine-Set möglich"
fi

if [[ "$OMB_INSTALL_GROK" == "1" ]]; then
    step "5b/7 Grok CLI via x.ai-Installer (kein npm-Paket)"
    curl -fsSL https://x.ai/cli/install.sh | bash - 2>&1 | tail -5 || \
        echo "WARNUNG: Grok-CLI-Installation fehlgeschlagen – kann später nachgeholt werden"
else
    step "5b/7 Grok CLI nicht gewählt – übersprungen"
fi

step "6/7 systemd-Units (openmausbot + Caddy-Config) + env-Datei installieren"
cp /root/openmausbot.service /etc/systemd/system/openmausbot.service
chmod 644 /etc/systemd/system/openmausbot.service
systemctl daemon-reload
systemctl enable openmausbot

cat > /etc/default/openmausbot <<ENVEOF
# Vom Installer verwaltet – wird bei --update neu geschrieben.
OMB_PORT=${OMB_PORT}
OMB_WEBHOOK_PORT=${OMB_WEBHOOK_PORT}
OMB_DATA_DIR=${OMB_DATA_DIR}
NODE_ENV=production
ENVEOF
if [[ -n "$OMB_PUBLIC_URL" ]]; then
    echo "OMB_PUBLIC_URL=${OMB_PUBLIC_URL}" >> /etc/default/openmausbot
fi
chmod 640 /etc/default/openmausbot
chown root:openmausbot /etc/default/openmausbot

# Caddy: Reverse Proxy 0.0.0.0:${OMB_WEB_PORT} → 127.0.0.1:${OMB_PORT} (+ /hooks/* → Webhooks)
cat > /etc/caddy/Caddyfile <<CADDYEOF
{
\admin off
}

:${OMB_WEB_PORT} {
	encode zstd gzip

	handle /hooks/* {
		reverse_proxy 127.0.0.1:${OMB_WEBHOOK_PORT}
	}

	handle {
		reverse_proxy 127.0.0.1:${OMB_PORT} {
			flush_interval -1
		}
	}
}
CADDYEOF
caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy

step "7/7 Rechte setzen + Services (neu) starten"
chown -R openmausbot:openmausbot "$OMB_HOME"
systemctl restart openmausbot
systemctl restart caddy

echo -e "\n━━━ [setup] In-Container-Setup abgeschlossen ━━━"
INNEREOF
}

# ── systemd-Unit erzeugen ──────────────────────────────────────────────────
write_service_unit() {
    cat > "$TMP_DIR/openmausbot.service" <<SVCEOF
[Unit]
Description=OpenMausBot – Self-hosted AI Agent Chat (Node-Harness-Server)
Documentation=https://github.com/milind-soni/OpenMausBot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openmausbot
Group=openmausbot
Environment=HOME=${OMB_HOME}
EnvironmentFile=/etc/default/openmausbot
ExecStart=/usr/bin/openmausbot serve
WorkingDirectory=${OMB_HOME}
Restart=always
RestartSec=5
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
SVCEOF
}

# ── Engine-Argumente in npm-Specs/Flags übersetzen ─────────────────────────
build_engine_flags() {
    NPM_ENGINES=""
    INSTALL_GROK=0
    local eng
    for eng in $INSTALL_ENGINES; do
        case "$eng" in
            claude) NPM_ENGINES="${NPM_ENGINES} @anthropic-ai/claude-code" ;;
            codex)  NPM_ENGINES="${NPM_ENGINES} @openai/codex" ;;
            grok)   INSTALL_GROK=1 ;;
        esac
    done
    NPM_ENGINES="${NPM_ENGINES# }"
    if [[ -n "$NPM_ENGINES" ]] && [[ "$INSTALL_GROK" == "1" ]]; then
        info "Engine-CLIs: ${NPM_ENGINES} + Grok (x.ai-Installer)"
    elif [[ -n "$NPM_ENGINES" ]]; then
        info "Engine-CLIs: ${NPM_ENGINES}"
    elif [[ "$INSTALL_GROK" == "1" ]]; then
        info "Engine-CLI: Grok (x.ai-Installer)"
    else
        info "Keine Engine-CLIs (--engines none) – später per Web-UI möglich"
    fi
    return 0
}

# ── Setup im Container ausführen (genutzt von install + update) ────────────
run_inner_setup() {
    local ct_id="$1"
    local ct_ip
    ct_ip=$(get_ct_ip "$ct_id")
    local public_url=""
    if [[ -n "$ct_ip" ]]; then
        public_url="http://${ct_ip}:${WEB_PORT}"
    fi

    header "Richte OpenMausBot in Container $ct_id ein (Version: ${OMB_VERSION})"

    TMP_DIR=$(mktemp -d /tmp/openmausbot-install-XXXXXX)
    write_inner_script
    write_service_unit
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    pct push "$ct_id" "$TMP_DIR/openmausbot.service" /root/openmausbot.service

    info "Führe In-Container-Setup aus (apt, Node 24, npm – kann 5–10 min dauern)..."
    pct exec "$ct_id" -- env \
        OMB_VERSION="$OMB_VERSION" \
        OMB_ENGINES_NPM="$NPM_ENGINES" \
        OMB_INSTALL_GROK="$INSTALL_GROK" \
        OMB_HOME="$OMB_HOME" \
        OMB_DATA_DIR="$OMB_DATA_DIR" \
        OMB_PORT="$OMB_PORT" \
        OMB_WEBHOOK_PORT="$OMB_WEBHOOK_PORT" \
        OMB_WEB_PORT="$WEB_PORT" \
        OMB_PUBLIC_URL="$public_url" \
        OMB_DEBUG="$([[ $DEBUG == true ]] && echo 1 || echo 0)" \
        bash /root/setup-inner.sh
    ok "In-Container-Setup abgeschlossen"
}

# ── Verifikation: Services + Web-UI (Server & Caddy) ───────────────────────
verify_installation() {
    local ct_id="$1"
    header "Verifiziere Installation"

    info "Service-Status prüfen..."
    if ! pct exec "$ct_id" -- systemctl is-active --quiet openmausbot; then
        err "Service 'openmausbot' läuft nicht."
        pct exec "$ct_id" -- sh -c 'systemctl status openmausbot --no-pager -l | head -30; \
            echo "--- journalctl ---"; journalctl -u openmausbot --no-pager | tail -40' || true
        die "Service-Check fehlgeschlagen.\n  Debug: pct enter $ct_id && journalctl -u openmausbot -e"
    fi
    ok "Service läuft (systemctl is-active)"

    if ! pct exec "$ct_id" -- systemctl is-active --quiet caddy; then
        err "Reverse-Proxy 'caddy' läuft nicht."
        pct exec "$ct_id" -- sh -c 'systemctl status caddy --no-pager -l | head -20; \
            echo "--- caddy validate ---"; caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -10' || true
        die "Caddy-Check fehlgeschlagen.\n  Debug: pct enter $ct_id && journalctl -u caddy -e"
    fi
    ok "Reverse-Proxy läuft (caddy)"

    info "Warte auf Web-UI (Server + Proxy, bis zu 2 min)..."
    local server_ok=false proxy_ok=false srv_code proxy_code
    for _ in $(seq 1 24); do
        if ! $server_ok; then
            # curl -w liefert bei Verbindungsfehler '000'; keine zweite Ausgabe via || echo
            srv_code="$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${OMB_PORT}/api/health" 2>/dev/null || true)"
            if [[ "$srv_code" =~ ^[0-9]{3}$ && "$srv_code" != "000" ]]; then
                server_ok=true
            fi
        fi
        if ! $proxy_ok; then
            proxy_code="$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null || true)"
            if [[ "$proxy_code" =~ ^[0-9]{3}$ && "$proxy_code" != "000" ]]; then
                proxy_ok=true
            fi
        fi
        if $server_ok && $proxy_ok; then
            break
        fi
        sleep 5
    done

    if ! $server_ok; then
        die "Server-API auf Port ${OMB_PORT} antwortet nicht.\n  Debug: pct enter $ct_id && journalctl -u openmausbot -e"
    fi
    ok "Server-API erreichbar (127.0.0.1:${OMB_PORT}/api/health, nur loopback – wie upstream-Design)"
    if ! $proxy_ok; then
        die "Web-UI über Caddy auf Port ${WEB_PORT} antwortet nicht.\n  Debug: pct enter $ct_id && journalctl -u caddy -e"
    fi
    ok "Web-UI über Reverse-Proxy erreichbar (Port ${WEB_PORT})"
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🐭  OpenMausBot ist bereit!"

    local ct_ip
    ct_ip=$(get_ct_ip "$CT_ID")
    [[ -z "$ct_ip" ]] && ct_ip="<IP-ADRESSE>"

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:    http://${ct_ip}:${WEB_PORT}${NC}"
    echo -e "  ${GREEN}  🔑 Pairing:   dieses Script mit --pair  → Code + Link ausgeben${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    echo -e "  ${GREEN}  🔑 Root-PW:   ${CT_PASSWORD}${NC}"
    echo -e "  ${GREEN}  📦 Version:   openmausbot ${OMB_VERSION}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}So geht's weiter:${NC}"
    echo "  1. Pairing-Code erzeugen:   dieses Script mit --pair"
    echo "     (Browser MÜSSEN sich koppeln – unauthentifiziert erscheint nur die Pair-Seite)"
    echo "  2. http://${ct_ip}:${WEB_PORT} öffnen → Code eingeben"
    echo "  3. KI-Zugang einrichten (eine Quelle reicht):"
    echo "     • Web-UI → Settings → Engines: Claude/Codex-Login (Headless-Flows, kein Browser nötig)"
    echo "     • oder API-Key: Settings → Connections → Model providers"
    echo "     • oder CLI im Container:"
    echo "         pct exec ${CT_ID} -- env HOME=${OMB_HOME} OMB_DATA_DIR=${OMB_DATA_DIR} \\"
    echo "           runuser -u openmausbot -- openmausbot engine set claude --key-env ANTHROPIC_API_KEY --install"
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle:${NC}"
    echo "  Status:    dieses Script mit --status"
    echo "  Pairing:   dieses Script mit --pair"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u openmausbot -f"
    echo "  Proxy-Log: pct exec ${CT_ID} -- journalctl -u caddy -f"
    echo "  Diagnose:  pct exec ${CT_ID} -- env HOME=${OMB_HOME} runuser -u openmausbot -- openmausbot doctor"
    echo "  Update:    dieses Script mit --update  (Version pinnen: --version X.Y.Z)"
    echo ""
}

# ── Update (Container bleibt, App wird aktualisiert) ───────────────────────
do_update() {
    local ct_id="$1"
    CT_ID="$ct_id"   # für die Fehlerkette (on_error) setzen
    header "Aktualisiere OpenMausBot in Container $ct_id"

    if ! pct exec "$ct_id" -- systemctl is-active openmausbot &>/dev/null; then
        warn "Service läuft aktuell nicht – Update wird ihn starten."
    fi

    build_engine_flags
    run_inner_setup "$ct_id"
    verify_installation "$ct_id"
    print_summary
    exit 0
}

# ── Container erstellen ────────────────────────────────────────────────────
create_container() {
    header "Erstelle LXC-Container (ID: $CT_ID)"

    pct create "$CT_ID" "local:vztmpl/${CT_TEMPLATE}" \
        --hostname "$CT_HOSTNAME" \
        --storage "$CT_STORAGE" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0" \
        --password "$CT_PASSWORD" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 0 \
        2>&1 | tail -3

    ok "Container $CT_ID erstellt ($CT_CORES vCPU, ${CT_MEMORY} MB RAM, ${CT_ROOTFS} GB Disk, onboot=1)"
}

# ── Hauptprogramm ──────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    echo ""
    echo -e "  ${BOLD}🐭  Proxmox OpenMausBot – Installer${NC}"
    echo -e "  ${CYAN}https://github.com/HatchetMan111/proxmox-openmausbot${NC}"
    echo -e "  ${CYAN}App: https://github.com/milind-soni/OpenMausBot (v${OMB_VERSION}, Apache-2.0)${NC}"
    echo -e "  ${CYAN}Log: $LOG_FILE${NC}"
    echo ""

    check_prerequisites

    # Bestehenden Container anhand Hostname finden (ID-Vorgabe hat Vorrang)
    local existing_id=""
    if [[ -n "$CT_ID" ]] && ct_exists "$CT_ID"; then
        existing_id="$CT_ID"
    else
        existing_id=$(find_existing_ct || true)
    fi

    if $UNINSTALL; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_uninstall "$existing_id"
    fi

    if $STATUS_CHECK; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_status "$existing_id"
    fi

    if $PAIR_MODE; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_pair "$existing_id"
    fi

    if $UPDATE; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_update "$existing_id"
    fi

    # Neuinstallation
    if [[ -n "$existing_id" ]]; then
        if $FORCE_RECREATE; then
            warn "--force-recreate: bestehender Container $existing_id wird GELÖSCHT (alle Daten verloren)!"
            confirm "Wirklich neu erstellen?" || die "Abgebrochen. (Tipp: --update aktualisiert ohne Datenverlust)"
            pct stop "$existing_id" 2>/dev/null || true
            sleep 2
            pct destroy "$existing_id" --purge 2>/dev/null
            CT_ID=""
        else
            info "Container '$CT_HOSTNAME' existiert bereits (ID $existing_id) – wechsle in den Update-Modus."
            info "(Neuinstallation erzwingen: --force-recreate)"
            do_update "$existing_id"
        fi
    fi

    find_free_id

    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -hex 12 2>/dev/null \
            || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' || echo "changeme")
        info "Root-Passwort automatisch generiert"
    fi

    build_engine_flags
    create_container

    pct start "$CT_ID" 2>&1 | tail -2
    ok "Container gestartet"

    info "Warte auf Netzwerk..."
    for _ in $(seq 1 60); do
        if [[ -n "$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | tr -d ' \n')" ]]; then
            break
        fi
        sleep 1
    done
    if [[ -z "$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | tr -d ' \n')" ]]; then
        die "Container hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $CT_ID -- ip a)"
    fi

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

main "$@"
