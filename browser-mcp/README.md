# Job Search Pipeline

General-purpose browser automation on a spare Android phone, exposed to AI agents
over MCP: a real Chromium, driven remotely, with a **queue** in front of it so
concurrent agents wait their turn instead of failing.

Status: **working slice, LAN-only.** No authentication and no tunnel yet — that is
Phase 2. Do not expose port 8930 publicly as it stands.

---

## The stack

```
agent → gateway.js (:8930)  →  @playwright/mcp (:8931)  →  Chromium 149 (headed)
         queue + status                                      on Xvnc :1 (1280x900)
```

| Piece | Why |
|---|---|
| **Chromium 149** | From Termux's own `x11-repo` — a native aarch64 build. **No proot, no Linux rootfs.** |
| **Xvnc :1** | Virtual display. Headed Chromium drops the headless fingerprint, and the same display can be attached to with a VNC viewer for hand-logins. |
| **openbox** | Minimal WM so windows get sized and focused properly. |
| **@playwright/mcp** | Upstream Microsoft server. 26 browser tools. Not reinvented. |
| **gateway.js** | Serializes browser access. The piece that had to be written. |

## Run it

```bash
./start.sh start      # brings up Xvnc, openbox, MCP, gateway in order
./start.sh status     # per-process state + live queue status
./start.sh stop
./start.sh restart
```

Connect an MCP client to `http://<phone>:8930/mcp` (Streamable HTTP). **Only over the
LAN or an SSH tunnel until Phase 2 adds auth.**

## Why the gateway exists

`@playwright/mcp` permits exactly one browser per `--user-data-dir`. A second session
that touches a browser tool fails immediately:

```
Error: Browser is already in use for <dir>, use --isolated to run multiple instances
```

Measured, 4 clients at once:

| | direct to `:8931` | through the gateway |
|---|---|---|
| Succeeded | **1 / 4** | **4 / 4** |
| Raw in-use errors | 3 | 0 |
| Timings | 1.0s, 1.0s, 1.0s (fail), 1.9s | 1.1s → 3.1s → 5.2s → 7.3s |

The staircase is the queue working: each client gets the browser as the previous one
lets go.

### What it does

- **FIFO queue** on browser tool calls (`browser_*`). Non-browser traffic
  (`initialize`, `tools/list`) is never serialized.
- **Idle reclaim** — a session holding the browser but silent for `GW_IDLE_RELEASE_MS`
  (default 120s) loses it to the next waiter, and its upstream session is closed. One
  crashed client cannot park the device.
- **Load shedding** — past `GW_MAX_QUEUE` (default 8) waiters, callers get a
  descriptive JSON-RPC error with `retry_after_s` instead of piling up.
- **Descriptive errors** — queue timeout and shed responses say what is happening and
  what to do. If the raw Playwright in-use string ever escapes, it gets rewritten.
- **Structured JSON logs** — one line per event.

```json
{"ts":"...","evt":"queued","sid":"2022ec55","depth":1,"holder":"d6a6fa88"}
{"ts":"...","evt":"idle_reclaim","sid":"d6a6fa88","idleMs":16077,"waiting":1}
{"ts":"...","evt":"lock_handoff","from":"d6a6fa88","to":"2022ec55","reason":"idle","waitedMs":15808}
```

### Status endpoint

```bash
curl -s http://127.0.0.1:8930/status
```

Reports whether the browser is busy, who holds it, how long they have held and been
idle, queue depth and per-waiter wait times, cumulative counters, and the live Chromium
process count.

### Tuning

| Env | Default | Meaning |
|---|---|---|
| `GW_PORT` | 8930 | gateway listen port |
| `GW_UPSTREAM_PORT` | 8931 | `@playwright/mcp` port |
| `GW_IDLE_RELEASE_MS` | 120000 | silence before a holder loses the browser |
| `GW_MAX_WAIT_MS` | 300000 | how long a queued call waits before erroring |
| `GW_MAX_QUEUE` | 8 | waiters before shedding |

## Logging in by hand

The browser runs on a real X display, so you can drive it yourself and leave the
session in the profile for agents to inherit — without ever handing over credentials.

VNC is bound to **loopback only** (verified: refused over the LAN). Tunnel to it:

```bash
ssh -p 8022 -N -L 5901:127.0.0.1:5901 <phone-ip>
# then point any VNC viewer at localhost:5901
# macOS: open vnc://localhost:5901
```

Log into the site in that window. The cookies land in the profile
(`~/job-search-pipeline-data/profiles/default`) and survive restarts — verified: cookies and
localStorage both persisted across a full process kill.

> Per-profile isolation and named profiles are **not** wired yet. Everything currently
> shares one profile. That is Phase 2.

## Adding a physical display later

Nothing above assumes a virtual display — only that `DISPLAY` points somewhere. To use
the phone's own screen, install `termux-x11`, start it instead of `Xvnc`, and set
`DISPLAY=:0`. `start.sh` takes `DISPLAY_NUM` and `GEOMETRY` as env vars for exactly
this. Chromium, MCP and the gateway need no changes.

## Headed vs headless — why headed

Same checks, same device, same IP:

| | headless | headed on Xvnc |
|---|---|---|
| bot.sannysoft.com failures | **4** — `User Agent (Old)`, `HEADCHR_UA`, `CHR_MEMORY`, `WebGL Renderer` | **1** — `WebGL Renderer` |
| UA contains `HeadlessChrome` | yes | no |
| Amazon | HTTP 202, 941 chars | HTTP 202, **1329 chars of real page** |
| Bing | 91 chars (soft block) | **3711 chars, fine** |
| Google | blocked | blocked |

The one remaining tell is the WebGL renderer reporting SwiftShader, because there is no
GPU access under X here. Google blocks either way.

Cost of headed: cold start 730ms vs 519ms. Worth it.

## Known limits

- **No sandbox.** Android has no user namespaces (`max_user_namespaces` absent,
  `unshare -U` → EINVAL) and no SUID helper ships. Chromium runs unsandboxed — a
  renderer compromise is a full Termux compromise. proot would not have fixed this.
- **One browser, one profile, right now.** Concurrency is *handled*, not *parallel*.
  Throughput is one page load at a time.
- **Snapshots get large.** Wikipedia's aria snapshot was 668 kB (~170k tokens) and took
  7.4s. Cheaper than the 3 MB of raw HTML, but it will still blow a context window.
- **Node reports `process.platform === 'android'`** on Termux, which Playwright rejects
  at import. `shim.cjs` (a one-line `Object.defineProperty`) is required on every
  `node` invocation.
- `@playwright/mcp` rejects requests whose `Host` is not what it is bound to — it will
  need `--allowed-hosts` once it sits behind the tunnel.
- `cloudflared` quick tunnels inherit `~/.cloudflared/config.yml` ingress rules; pass
  `--config` with an empty file to isolate them.

## Files

```
gateway.js            the queue / status / logging front-end
start.sh              brings the stack up in order
test-concurrency.sh   fires N simultaneous clients, shows they serialize
soak.sh               unattended endurance test (page load every 30 min)
bench.mjs             cold start, navigation, memory, profile persistence
display-bench.mjs     headless vs headed fingerprint and gatekeeper comparison
```
