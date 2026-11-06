# 🐭 Proxmox OpenMausBot

[OpenMausBot](https://github.com/milind-soni/OpenMausBot) als Ein-Klick-Installer für **Proxmox VE** – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

OpenMausBot ist eine self-hosted Chat-Oberfläche, in der jeder „Bot" in der Sidebar ein echter KI-Agent ist (Claude Code, Codex oder Grok CLI) mit eigenem Modell, eigener Persönlichkeit und eigenem Gedächtnis – inkl. Computer-Use, Webhooks, geplanten Routinen und MCP-Orchestrierung. Apache-2.0, kein Cloud-Zwang: Läuft **vollständig lokal** in deinem LAN.

| | |
|---|---|
| **Web-UI** | `http://<CT-IP>:8080` (über Caddy, **Pairing-Code nötig** – siehe unten) |
| **Server** | Port `8799` – **nur loopback** (Sicherheitsdesign des upstream, nicht von außen erreichbar) |
| **Webhooks** | Port `8800` – nur loopback, extern via `http://<CT-IP>:8080/hooks/*` |
| **Container** | LXC, unprivileged, Debian 12, 2 vCPU · 3 GB RAM · 16 GB Disk |
| **App-Version** | gepinnt (`0.1.144`), Apache-2.0 |
| **Engines** | `@anthropic-ai/claude-code` + `@openai/codex` werden mitinstalliert (Login machst du selbst) |
| **Daten** | `/opt/openmausbot/data` im Container (bleibt bei `--update` erhalten) |

---

## 🚀 Installation (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/proxmox-openmausbot/main/install/openmausbot.sh)"
```

Das Script:
1. nimmt automatisch die **nächste freie CT-ID** (ab 200) und erstellt einen unprivilegierten LXC (`openmausbot`, `onboot=1`, `nesting=1`),
2. installiert **Node 24**, `openmausbot` (npm, gepinnt) + Engine-CLIs und Caddy,
3. richtet den **systemd-Service** ein (`Restart=always`, `After=network-online.target`) und den **Caddy-Reverse-Proxy** (`0.0.0.0:8080 → 127.0.0.1:8799`, SSE-fähig via `flush_interval -1`),
4. **verifiziert** beide Services + Web-UI (HTTP-Checks auf `/api/health` und Proxy) und gibt die finale URL aus.

Erwartete Ausgabe (Ende):

```
✔ Service läuft (systemctl is-active)
✔ Reverse-Proxy läuft (caddy)
✔ Server-API erreichbar (127.0.0.1:8799/api/health, nur loopback – wie upstream-Design)
✔ Web-UI über Reverse-Proxy erreichbar (Port 8080)

━━━ 🐭  OpenMausBot ist bereit! ━━━
  🌐 Web-UI:    http://192.168.x.x:8080
  🔑 Pairing:   dieses Script mit --pair  → Code + Link ausgeben
  🔑 Root-PW:   <generiertes Passwort>
  📦 Version:   openmausbot 0.1.144
```

---

## 🔑 Erste Schritte (Pairing + KI-Zugang)

### 1. Pairing-Code erzeugen – PFLICHT, auch im LAN!

Der OpenMausBot-Server vertraut Browsern **bewusst nie direkt** – unauthentifizierte Browser sehen nur die Pairing-Seite. So koppelst du deinen Browser:

```bash
# auf dem Proxmox-Host:
.../install/openmausbot.sh --pair
```

→ gibt einen **12-stelligen Einmal-Code** (24 h gültig) + einen fertigen Link aus. Im Browser `http://<CT-IP>:8080` öffnen, Code eingeben – fertig.

### 2. KI-Zugang einrichten (eine Quelle reicht)

* **Web-UI (empfohlen):** Settings → **Engines** → Claude/Codex-Login (Headless-Flows: Device-Code bzw. Paste-Back-Code – kein Browser im Container nötig)
* **API-Key:** Settings → Connections → Model providers (z. B. `ANTHROPIC_API_KEY`)
* **CLI im Container:**
  ```bash
  pct exec <CT-ID> -- env HOME=/opt/openmausbot OMB_DATA_DIR=/opt/openmausbot/data \
      runuser -u openmausbot -- openmausbot engine set claude --key-env ANTHROPIC_API_KEY --install
  ```

Ohne KI-Zugang startet die UI trotzdem – Chats brauchen dann mindestens eine eingerichtete Engine.

---

## ⚙️ Optionen

| Option | Default | Beschreibung |
|---|---|---|
| `--id NUM` | automatisch ab 200 | Container-ID |
| `--hostname TEXT` | `openmausbot` | Hostname |
| `--storage TEXT` | `local-lvm` | Proxmox-Storage |
| `--rootfs NUM` | `16` | Disk in GB |
| `--cores NUM` | `2` | vCPUs |
| `--memory NUM` | `3072` | RAM in MB |
| `--ip ADDR` | `dhcp` | Statische IP, z. B. `192.168.1.51/24` |
| `--port NUM` | `8080` | Externer Web-UI-Port (Caddy) |
| `--engines LIST` | `claude codex` | Engine-CLIs: `claude`, `codex`, `grok` (x.ai-Installer) oder `none` |
| `--version VER` | `0.1.144` | App-Version pinnen (`latest` = immer neueste) |
| `--password TEXT` | generiert | Root-Passwort des CT |
| `--template TEXT` | debian-12-standard | CT-Template |

## 🛠 Verwaltung (jeweils derselbe Einzeiler + Flag)

```bash
... --status            # Container-/Service-Status + HTTP-Check von außen
... --pair              # Neuen Pairing-Code erzeugen
... --update            # App im Container aktualisieren (Daten bleiben)
... --update --version 0.2.0   # auf konkrete Version
... --uninstall --yes   # Container inkl. Daten löschen
... --debug             # Installation mit vollem bash -x-Trace wiederholen
```

Bei Fehlern gibt das Script die **komplette Fehlerkette** aus (Zeile, Befehl, Exit-Code, Log-Auszüge, Container-Logs) und löscht den Container nicht – Inspektion mit `pct enter <CT-ID>`.

## 🏗 Architektur

Der OpenMausBot-Server bindet **absichtlich nur `127.0.0.1`** (upstream-Sicherheitsdesign: *„Never expose that port directly"*). Genau wie im offiziellen Docker-Setup liegt deshalb ein Caddy davor:

```
Browser ──HTTP :8080──▶ Caddy ──▶ 127.0.0.1:8799   Web-UI/Server (SSE: flush_interval -1)
                            └──▶ 127.0.0.1:8800    Webhooks (/hooks/*, eigene Secrets)
```

* systemd-Units: `openmausbot.service` (User `openmausbot`, `Restart=always`, env in `/etc/default/openmausbot`) + `caddy.service` (beide `systemctl enable`)
* Container: `onboot=1` → nach Proxmox-Reboot startet alles selbstständig
* Engine-Logins/Keys liegen im Container unter `~/.claude`, `~/.codex` bzw. `/opt/openmausbot/data` (Owner-only)

## 🩺 Troubleshooting

```bash
pct exec <CT-ID> -- journalctl -u openmausbot -e     # App-Logs
pct exec <CT-ID> -- journalctl -u caddy -e           # Proxy-Logs
pct exec <CT-ID> -- env HOME=/opt/openmausbot runuser -u openmausbot -- openmausbot doctor
... --debug                                          # Installer mit bash -x erneut ausführen
```

* **Pairing-Seite erscheint endlos** → Code abgelaufen/eingelöst? Neu erzeugen: `--pair`
* **UI erreichbar, aber keine Antwort im Chat** → Engine eingerichtet? (Siehe „KI-Zugang")
* **`openmausbot` aktualisieren auf latest:** `--update --version latest`

## 📄 Lizenz & Credits

* Installer: MIT – © 2026 HatchetMan111
* [OpenMausBot](https://github.com/milind-soni/OpenMausBot) von Milind Soni – Apache-2.0 (nicht Teil dieses Repos; wird bei der Installation aus npm bezogen)
* Nicht mit xAI, Meta, OpenAI oder Manus affiliiert.
