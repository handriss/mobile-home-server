# Phone Home Server

Turn a spare Android phone into an always-on **Termux + nginx** web server, provisioned
from a Mac over ADB with **minimal human intervention**. Repeatable for any phone.

Built and validated on an **OPPO Reno5 Z (CPH2211), Android 13 / ColorOS**.

---

## What you get

- nginx serving a website from the phone, on your LAN (`http://<phone-ip>:8080`)
- Auto-start on boot + a held wake-lock (survives reboots, screen-off, doze)
- Battery-optimization exemption so Android doesn't kill it
- One-command site deploys from the Mac
- Optional public access via Cloudflare Tunnel (works even behind CGNAT / DS-Lite)
- The phone driveable from the Mac forever after (no on-screen typing needed)

---

## The only manual steps (Android security requires these)

Everything else is automated. On the **phone**:

1. **Settings → About phone → tap "Build number" 7×** → enables Developer options.
2. **Settings → (System →) Developer options → turn ON "USB debugging".**
   Also turn ON **"Stay awake"** (screen stays on while charging — very handy if the
   phone's power button is broken).
3. **Connect the phone to the same Wi-Fi as the Mac.**
4. **Plug the phone into the Mac with a DATA cable**, then on the phone tap
   **"Allow USB debugging"** and tick *"Always allow from this computer"*.

Prereqs on the **Mac**: `brew install android-platform-tools` (adb) and `python3`.

---

## Run it

```bash
./provision.sh                 # auto-detects the single attached phone
./provision.sh --port 8080     # nginx port (default 8080; must be >= 1024)
./provision.sh --serial <adb-serial>   # if several devices are attached
```

Takes ~4–5 minutes (mostly the Termux package upgrade). At the end it prints the
live URL and verifies it returns HTTP 200.

---

## Deploy a website

Your site is just the files in nginx's docroot on the phone
(`/data/data/com.termux/files/usr/share/nginx/html/`). To ship a folder:

```bash
scripts/deploy.sh ./my-site           # replaces the served site with ./my-site/*
```

It tars the folder, serves it briefly from the Mac, and has Termux fetch+extract it —
no storage permissions, no typing. Edit `www/index.html` for the default page.

**Deploy over WiFi (no cable)** — once `scripts/setup-ssh.sh` has run (installs Termux
`sshd`, key-based, auto-starts on boot, port 8022):
```bash
scripts/deploy-ssh.sh ./www                 # scp over WiFi + reload nginx, no ADB
ssh -p 8022 <phone-ip> 'nginx -s reload'    # any command; Termux accepts any username
```

## Diagnostics page

`www/diag.html` is a self-contained dashboard (temperature chart with 43/48°C threshold
lines, battery-level chart, live stat tiles, 24h/3d/7d toggle, auto-refresh). The battery
monitor writes `batt.json` into the docroot every 5 min, so the page just loads:
**`http://<phone-ip>:8080/diag.html`**. No server-side code — nginx serves static files.

> **Keep this on the LAN.** `batt.json` sits in the docroot and is served without any
> authentication, so anyone who can reach nginx gets 7 days of battery, temperature and
> uptime samples — which is a presence side channel: it shows when the device charges and
> when it rebooted. If you put the Cloudflare Tunnel in front of port 8080, put Cloudflare
> Access (or at least basic auth) in front of it too.

---

## Maintenance from the Mac

After provisioning, run any command inside Termux from the Mac:

```bash
scripts/termux-run.sh 'apt update && apt full-upgrade -y'   # update Termux packages
scripts/termux-run.sh 'nginx -s reload'                     # reload config
scripts/termux-run.sh 'nginx -s stop; nginx'                # restart nginx
```

It wraps your command in a script, serves it from the Mac, and types the
operator-free `curl -o` + `bash` into Termux — so `>`, `|`, `&&` all work (they run
inside Termux). The command appears typed on the phone screen; output stays on the
phone, so verify effects separately (e.g. `curl http://<phone-ip>:8080`).

---

## Cloudflare Tunnel (optional public access)

`cloudflared` is installed by provisioning but **not started**. It lets the outside
world reach the phone with automatic HTTPS, without opening router ports — and it
works behind CGNAT / DS-Lite (no public IP needed) because the phone dials *out* to
Cloudflare's edge.

**Quick test tunnel** (random URL, ephemeral, dies on reboot):
```bash
# start it in the background and capture the URL to a log:
scripts/termux-run.sh 'pkill cloudflared; cloudflared tunnel --url http://localhost:8080 > ~/cf.log 2>&1 &'
sleep 10
scripts/termux-run.sh 'grep -o "https://[a-z0-9-]*\.trycloudflare\.com" ~/cf.log > $PREFIX/share/nginx/html/_tunnel.txt'
curl -s http://<phone-ip>:8080/_tunnel.txt      # <- your public URL
```
Stop it with `scripts/termux-run.sh 'pkill cloudflared'`.

**Permanent named tunnel** (stable URL on your own domain, auto-starts on boot) —
needs a Cloudflare account + a domain on Cloudflare + a one-time browser login:
1. `scripts/termux-run.sh 'cloudflared tunnel login'` → open the printed URL on any
   browser, authorize, pick your domain (writes `~/.cloudflared/cert.pem`).
2. `cloudflared tunnel create home` ; `cloudflared tunnel route dns home home.example.com`
3. Write `~/.cloudflared/config.yml` pointing the tunnel at `http://localhost:8080`.
4. Add `cloudflared tunnel run home &` to `~/.termux/boot/start-server.sh` so it
   auto-starts alongside nginx.

---

## How it works (and the gotchas it handles)

- **Driving Termux from ADB:** `adb shell input text` drops spaces and needs the soft
  keyboard focused, so `provision.sh` taps the terminal first, then types commands
  word-by-word injecting SPACE (keyevent 62) / ENTER (66). Big multi-line files
  (the site, the boot script) are fetched via a temporary HTTP server on the Mac +
  `curl` on the phone instead of typed.
- **The curl/openssl breakage:** a fresh Termux bootstrap's `curl` fails with
  `cannot locate symbol SSL_set_quic_tls_transport_params`, and `pkg` uses curl. Fix:
  use `apt` directly and `apt full-upgrade` **before** installing curl, so curl and
  openssl land at matching versions. `-o Dpkg::Options::=--force-confold` avoids the
  interactive config-file prompts.
- **Auto-start on ColorOS/OPPO:** Termux:Boot must be *opened once* (Android keeps
  never-launched apps in a "stopped" state that blocks boot broadcasts). Provisioning
  launches it. Combined with the doze whitelist, boot-start survives OPPO's aggressive
  background management (verified with a real reboot).
- **Ports:** Android forbids binding <1024 even in Termux, so nginx uses 8080.

---

## Battery safety monitor

A no-root watchdog (`scripts/battery-monitor.sh`) that reads battery data via
**Termux:API** (`termux-battery-status` — the raw `/sys` nodes are SELinux-blocked
for apps), pushes **ntfy** alerts, pings a **healthchecks.io** dead-man's switch, and
sends a **daily digest**. Config lives on the phone at `~/batt-monitor/monitor.conf`;
it auto-starts via `~/.termux/boot/battery-monitor.sh`.

**Install it (one command)** — handles the Termux:API app + package, deploys the
monitor, and starts it:
```bash
scripts/setup-monitor.sh                                   # random topic, heartbeat off
NTFY_TOPIC=my-topic HEALTHCHECK_URL=https://hc-ping.com/xxxx NAME=oppo-server \
  scripts/setup-monitor.sh                                 # or set them explicitly
# then: install the ntfy app and subscribe to the printed topic
```

Thresholds (edit `~/batt-monitor/monitor.conf`, then restart the monitor):

| Setting | Default | Meaning |
|---|---|---|
| `TEMP_WARN` | 43 °C | high-priority "warming" ntfy alert |
| `TEMP_URGENT` | 48 °C | urgent "hot" alert (breaks through Do-Not-Disturb) |
| `POLL_SECS` | 300 | sample interval |
| `DIGEST_HOUR` | 9 | local hour for the daily report |
| `NTFY_TOPIC` | *(random)* | ntfy.sh topic you subscribe to |
| `HEALTHCHECK_URL` | *(empty)* | healthchecks.io ping URL; empty = heartbeat off |

Alerts fire only on **transitions** (once when bad, once when recovered) — no spam.
Health alerts only on genuinely-bad states (`OVERHEAT`/`DEAD`/`OVER_VOLTAGE`/`COLD`/
`UNSPECIFIED_FAILURE`); `GOOD`/`UNKNOWN` are quiet.

```bash
scripts/termux-run.sh 'bash $HOME/batt-monitor/monitor.sh digest'   # preview the digest now
scripts/termux-run.sh 'pkill -f batt-monitor/monitor.sh'            # stop it
# remove entirely: pkill it, then delete ~/batt-monitor and ~/.termux/boot/battery-monitor.sh
```

**What it can't do:** cap the charge level. On this non-rooted OPPO the charge-control
nodes (`/sys/class/oplus_chg/battery/mmi_charging_enable`, `stop_charging_enable`) are
root/system-owned — writes are denied, and the OPLUS charging daemon would override them
anyway. Holding ≤70% needs a **smart plug** (ideally closed-loop: the phone reads its own
% and toggles a LAN smart plug). SoH isn't in the live digest either (BatteryManager
doesn't expose `charge_full`); it was ~94% (fcc 4073 / design 4310 mAh) when measured.

## Troubleshooting

- **`provision.sh` verify fails:** the typed-command phase is the fragile part
  (timing/focus). Open Termux on the phone — did it reach a `$` prompt? Re-run
  `./provision.sh` (idempotent) or `scripts/termux-run.sh 'bash s.sh <mac-ip> 8000 8080'`.
- **No ADB device / "unauthorized":** replug the data cable; tap "Allow USB debugging".
  After a phone **reboot**, ADB drops and OPPO can take ~20s to re-expose USB adb;
  `adb tcpip` (wireless) does **not** survive reboot.
- **Different phone model:** the `focus_termux` tap coordinate (`540 800`) and sleep
  timings may need adjusting for other screen sizes/speeds.
- **Gifting the phone later:** remove any signed-in accounts (Settings → Accounts) and
  factory-reset — ADB can't guarantee credential/account removal without root.

---

## Files

```
provision.sh              main orchestrator — run this on the Mac
scripts/termux-setup.sh   runs inside Termux (fetched by provision.sh): site + boot + start
scripts/termux-run.sh     run any command inside Termux from the Mac
scripts/deploy.sh         deploy a local site folder to the phone (over ADB)
scripts/setup-ssh.sh      install Termux sshd (once) -> WiFi deploys, no more cable
scripts/deploy-ssh.sh     deploy a site folder over WiFi (scp), no ADB
scripts/setup-monitor.sh  install the battery monitor (Termux:API + ntfy + heartbeat)
scripts/battery-monitor.sh  the monitor loop (alerts, digest, writes batt.json)
scripts/lib.sh            shared ADB/Termux helpers (sourced by run + deploy)
www/index.html            default page (edit or replace via deploy.sh)
www/diag.html             battery/temperature diagnostics dashboard
cache/                    downloaded Termux APKs (gitignored)
```
