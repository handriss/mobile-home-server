# Job Search Pipeline

General-purpose browser automation on a spare Android phone, exposed to AI agents
over MCP: a real Chromium, driven remotely, with a **queue** in front of it so
concurrent agents wait their turn instead of failing.

Status: **auth implemented and unit-tested; tunnel not yet wired.** The gateway is now its
own OAuth 2.1 authority (see *Authentication* below) and refuses every unauthenticated
request that arrives through a tunnel, `/status` included. The Cloudflare ingress rule and
a live end-to-end test on the phone are still outstanding — see *Deploying the tunnel*.

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

## Authentication

The gateway is its own OAuth 2.1 authorization server (`auth.js`), a direct port of the
scheme already proven on this phone by `youtube-transcript-mcp/server.py`. Cloudflare Access
is deliberately **not** used: its DCR endpoint 404s, and claude.ai web is broken against CF
Managed OAuth.

Two ways in:

| Client | Method |
|---|---|
| claude.ai web, any MCP client that does OAuth | RFC 7591 dynamic registration → PKCE S256 → **owner-password consent page** |
| Claude Code, curl, scripts | Static bearer in `Authorization: Bearer <token>` |

Secrets are generated on first run and persisted `0600` in `~/.config/browser-mcp/`
(`oauth_secret`, `password`, `bearer_token`). They are **never** in this repo. Because the
signing key is persisted, tokens survive a gateway restart — you authorize once.

Access tokens last 24 h, refresh tokens 90 d. Authorization codes are single-use and expire
in 10 minutes.

**The owner password is the entire perimeter** once the tunnel is public — the consent page
grants full control of a real browser holding your logged-in sessions. Treat it accordingly.

### What is *not* behind auth

Only the OAuth discovery, registration, consent and token endpoints — a client cannot
present a token before it has one. Everything else, `/status` and `/mcp` alike, requires a
valid bearer.

On-device callers over plain loopback (`soak.sh`, `start.sh`) are exempt, since they cannot
be reached from outside. Tunnelled requests also arrive from `127.0.0.1`, so the exemption
keys off the *absence* of cloudflared's forwarding headers, not the socket address alone.

### Verified locally

Registration, consent, PKCE exchange, refresh, and static bearer all pass; so do the
negative cases — wrong password, wrong PKCE verifier, `redirect_uri` mismatch, unregistered
`redirect_uri`, authorization-code replay, and a forged token. **Not yet tested against the
live phone or through the tunnel.**

## Deploying the tunnel

Not yet done. `BROWSER_MCP_PUBLIC_URL` **must** be set when exposing this, so OAuth metadata
advertises a fixed origin rather than trusting the `Host` header. The chosen hostname is
**`browser.example.com`**:

```sh
BROWSER_MCP_PUBLIC_URL=https://browser.example.com ./start.sh restart
```

Then add an ingress rule to the phone's existing named tunnel (`~/.cloudflared/config.yml`),
alongside the yt-mcp one, and create the DNS record. `@playwright/mcp` rejects requests whose
`Host` is not what it bound to — the gateway already rewrites `Host` when proxying upstream,
so that is handled, but re-check it after the first live request.

## Recovery: two tiers, and why the inner one is not enough

`supervise.sh` polls every 15 s and restarts what is missing. It is fast, and it is also
an ordinary Termux process — so it dies in exactly the events it exists to recover from.
That happened twice (2026-09-16, 2026-09-18), each time taking sshd recovery with it and
leaving the device unreachable until something outside Termux intervened.

That something is **Android's JobScheduler**, via `termux-job-scheduler --persisted true`.
Android relaunches Termux to run the job even after killing it, so a job registered there
survives anything that happens inside Termux. The Forgejo project on this phone already
used it (`~/forgejo/schedule-watchdog.sh`, job 4272, 15-minute period — Android's minimum),
and that job rescued the device every single time.

The browser stack is now registered with the same job:

| Tier | Mechanism | Period | Survives a Termux-wide kill? |
|---|---|---|---|
| Fast | `supervise.sh` | 15 s | **No** |
| Outer | `~/forgejo/watchdog.sh` via JobScheduler | 15 min | **Yes** |

The outer tier restarts the browser stack *and* `supervise.sh` itself. Verified: killing the
supervisor, the gateway and Xvnc, then running the watchdog, produced
`watchdog restarted: browser-stack browser-supervisor` and a gateway answering again.

So worst case you are down for up to 15 minutes rather than until someone picks the phone
up. If you need faster, the fast tier is what provides it — when it is alive.

## One browser at a time

`GW_NO_STATIC_UPSTREAM=1` stops `start.sh` launching an always-on default browser; the
gateway spawns whichever profile is asked for. This is what makes `GW_MAX_LIVE_PROFILES=1`
an enforceable limit — an *adopted static* upstream is exempt from eviction, so with one
running you always got a second browser the moment any named profile was used.

**Every process-shedding incident on this device had two or more concurrent Chromiums.**
Four for four. Not proof, but it is the only condition common to all of them, and the
mitigation is cheap.

> This also settles **per-profile locking**: with one browser there is nothing to unlock in
> parallel. Building it would mean deliberately running the configuration that breaks this
> device. Deferred on purpose, not forgotten.

At idle the healthy state is now **no browser and no upstream at all** — `soak.sh` therefore
measures liveness by asking the gateway, not by looking for a `@playwright/mcp` process.

## Co-tenancy: what else lives on this phone

This is not a dedicated device. nginx (:8080), yt-transcript-MCP (:8765), Forgejo (:3000),
forgejo-MCP (:8766) and the battery monitor all share it. **Memory has never been the
constraint** (~4.5 GB free with two Chromiums running); the failures have been individual
processes dying or wedging.

Two incidents on 2026-09-16, both in windows just after the probe suite ran:

- **sshd died** — recovered by the Forgejo watchdog ~11 min later. `supervise.sh` now watches
  it every 15 s instead.
- **forgejo-MCP wedged** — the process was alive but unresponsive, and stayed that way ~5.5 h
  because nothing started or watched it. Now has `~/.termux/boot/55-forgejo-mcp.sh` and is in
  the soak's neighbour list.

Correlation with the probe suite is **unproven** — `probe_shed` fires `GW_MAX_QUEUE+3`
simultaneous clients, which is the obvious suspect, but two earlier causal theories about
these incidents turned out to be wrong. Until it is understood, run genuinely unattended
soaks with `SOAK_PROBE_EVERY=0` and run probes by hand while watching:

```sh
SOAK_PROBE_EVERY=0 SOAK_NEIGHBOURS="8080:nginx 8765:yt-mcp 3000:forgejo 8766:forgejo-mcp" \
  ./soak.sh start
```

### Diagnosing a dead service from off-LAN

Probe the **tunnel hostname**, never the LAN port — Forgejo, forgejo-MCP and the gateway all
bind `127.0.0.1`, so an external port scan always reads "down" whether they are healthy or
not. Through the tunnel, **502 means the tunnel is up but the origin is not answering**
(process dead or wedged); 302/404 means healthy.

### Two process-identification traps on this device

- `pgrep -f <pattern>` run inside an `ssh ... '<script>'` **matches the script's own command
  line**. Use `ps -ef | grep "[p]attern"` instead.
- yt-MCP and forgejo-MCP both run as `python -u server.py` — argv cannot tell them apart.
  Identify by `/proc/<pid>/cwd`, as `forgejo-mcp/run.sh` does. `~/.termux/boot/30-yt-mcp.sh`
  guards with a bare `pgrep -f server.py`, which is why the forgejo-MCP boot script must be
  numbered **after** it.

## Snapshot cost

`browser_snapshot` on a large page is very expensive. Measured on this device:

| Tool | Wikipedia "Android" | ≈ tokens |
|---|---:|---:|
| `browser_snapshot` | 1,302,514 B | ~326,000 |
| `browser_find` (`text="Linux kernel"`, 29 matches) | 23,586 B | ~5,900 |
| `browser_evaluate` (targeted extract) | 599 B | ~150 |

Worse, an agent loop re-sends that snapshot every turn. Prefer `browser_find` to locate an
element and get its `ref`, and `browser_evaluate` to pull specific text; reserve
`browser_snapshot` for small pages. Sizes are logged on every call
(`{"evt":"snapshot_size"}`); set `GW_MAX_SNAPSHOT_BYTES` to refuse oversized ones with a
message pointing at the cheaper tools.

## Named profiles

`/mcp` is the default profile; **`/mcp/<name>`** selects another. Each profile gets its own
`@playwright/mcp` upstream with its own `--user-data-dir`, spawned on first use and torn
down after `GW_PROFILE_IDLE_MS` of silence.

```
https://browser.example.com/mcp            -> profile "default"
https://browser.example.com/mcp/work       -> profile "work"
https://browser.example.com/mcp/personal   -> profile "personal"
```

Point each agent at the URL for the profile it should use. Names are `[a-z0-9_-]`, max 32
chars; anything else gets a 400.

Verified end-to-end through the gateway against real browsers:

| Check | Result |
|---|---|
| Cookies + localStorage survive a full upstream stop and restart on a new port | pass |
| `work`, `personal` and `default` each read back only their own state | pass |
| An unused profile starts empty | pass |
| Concurrent first-use of one profile shares a single spawn (no double browser on one dir) | pass |
| LRU eviction past `GW_MAX_LIVE_PROFILES` | pass |

`start.sh` launches one upstream itself; the gateway **adopts** it as the default profile
rather than spawning a second browser onto the same directory.

| Env | Default | Meaning |
|---|---|---|
| `GW_DEFAULT_PROFILE` | `default` | profile used for bare `/mcp` |
| `GW_MAX_LIVE_PROFILES` | 2 | browsers alive at once — this is a phone |
| `GW_PROFILE_IDLE_MS` | 600000 | idle before a profile's browser is torn down |
| `GW_PROFILE_PORT_BASE` | 8940 | first port for spawned upstreams |

> Concurrency is still **globally serialized** — one page load at a time across all
> profiles. Profiles give isolation and persistence, not parallelism. Per-profile parallel
> locking is #6.

### Logging into a profile by hand

```sh
./login.sh --list                       # what profiles exist, which are live
./login.sh work https://example.com/    # open 'work' and hold it while you sign in
./login.sh work --check https://site/   # what is this profile signed into there?
```

`login.sh` handles the two things that make a hand-login work, which are **not** the same
thing:

1. the profile's **upstream** must stay alive — `/profiles/<name>/pin`;
2. an **MCP session** must stay open — the browser window belongs to the session, not the
   server, so closing the session closes Chromium. The gateway also reclaims a session that
   goes quiet for `GW_IDLE_RELEASE_MS`, which would shut the window mid-login, so `login.sh`
   heartbeats it.

Every profile's Chromium is headed on the same Xvnc display, so one VNC connection reaches
all of them; `login.sh` renames the relevant window to `PROFILE: <name>` and raises it so
you can tell several apart. Credentials go straight into that profile's Chromium — never
through an agent, this script, or the gateway.

Management endpoints (authenticated like everything else):

| Route | Does |
|---|---|
| `GET /profiles` | known + live profiles, which are pinned |
| `POST /profiles/<name>/pin` | start it and hold it open |
| `POST /profiles/<name>/unpin` | release it to normal idle teardown |

> A pinned profile is exempt from both idle teardown and LRU eviction, so pinning can push
> the live count above `GW_MAX_LIVE_PROFILES`. That is deliberate — a pin is a human
> sitting at the screen — but it does mean an abandoned pin holds a browser open.

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
auth.js               OAuth 2.1 authority + static bearer (see Authentication)
profiles.js           per-profile upstream pool: spawn, adopt, evict, idle teardown
start.sh              brings the stack up in order
test-concurrency.sh   fires N simultaneous clients, shows they serialize
login.sh              hand-login into a named profile (#5)
soak.sh               unattended endurance test, with guard rails (see below)
probes.sh             corner-case probes: concurrency, shed, badurl, slowpage, abandon
report.sh             turns a soak run into a verdict
bench.mjs             cold start, navigation, memory, profile persistence
display-bench.mjs     headless vs headed fingerprint and gatekeeper comparison
```
