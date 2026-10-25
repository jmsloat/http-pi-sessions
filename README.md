# Session Desk — integration prototype

A single-user, self-hosted coding-agent workspace in **Elixir + Phoenix LiveView**.
The host owns a Pi session; browser pages subscribe to it. Gentle Shell owns the
to-do list and questions. Authentication and TLS belong to your reverse proxy.

This is an integration prototype, not the full application. It has one configured
workspace and one session: streaming text, Gentle Todo, expandable tool results,
RPC questions, stop, browser reconnect, and reopening saved Pi history. There is
no project manager, file/diff panel, worktree creation, or deployment configuration
yet. No database is needed for this single-session slice; the eventual app metadata
store is planned to use SQLite.

## Run the demo

Requirements: Elixir 1.18+, Erlang/OTP 27+, a C++ compiler and make (for erlexec),
and Node 22.19+ (also required by the tested Pi/Gentle versions).

```sh
mix local.hex --force
mix local.rebar --force
mix setup
mix phx.server
```

Open http://localhost:4000. Send a message, watch the plan appear, refresh while
the agent is working, and answer its question. **Demo mode is a scripted RPC
fixture, not a language model.** It performs no workspace operations. Its history
is stored in `data/demo.json`.

## Use your Pi + Gentle installation

Use the Pi executable and agent home that already contain your Gentle configuration
and provider credentials. The web app doesn't install or update that configuration.
Pi 1.4.0 and gentle-pi 4.3.0 are the initial integration baseline.

```sh
SESSION_DESK_MODE=live \
PI_EXECUTABLE=/absolute/path/to/pi \
PI_CODING_AGENT_DIR=/absolute/path/to/your/configured/agent-home \
WORKSPACE=/absolute/path/to/repository \
DATA_DIR=/absolute/path/to/session-desk-data \
mix phx.server
```

The app starts Pi directly with `--mode rpc --session DATA_DIR/pi-session.jsonl`.
It sets `GENTLE_SHELL_INTERACTIVE_HOST=1`, which enables Gentle's native RPC question
fallbacks. Optional `PI_ARGS_JSON` is a JSON array, for example
`["--provider","anthropic","--model","your-model-id"]`. Arguments are passed
directly to the process, not interpolated into a shell command.

Gentle must actually be loaded in that Pi home; selecting live mode alone does not
install it. Gentle's launcher may use a separate home or a bundled Pi executable,
so configure the paths from your own installation rather than assuming a location.

## Behavior and limits

- Browser disconnects do not own or stop the agent process. The page subscribes
  before obtaining a snapshot and ignores older state revisions after reconnect.
- One active prompt at a time. Steering/follow-up queues are deliberately absent
  from this prototype. Failed prompts are reported, not silently retried.
- Gentle task snapshots come from `result.details.gentleTodo` and saved tool-result
  messages. IDs, order, notes, blocked/dropped states, and update turns are retained.
  Gentle's `setWidget` clear notification clears the visible plan. No replacement
  to-do tool is registered. Completed plans disappear when reopening saved history.
- Select, confirm, input, and editor RPC dialogs are supported. Gentle multi-select
  uses its native repeated-select protocol. Answers are checked against the pending
  request, so duplicate/stale answers from another tab are rejected.
- The transcript currently renders escaped plain text, including code fences.
  Rich Markdown and file previews are future work. Tool activity is bounded to the
  last 100 calls; long-conversation pagination is not implemented yet.
- Pi persists history. Pending dialogs are only live process state and do not
  survive an agent/container restart. Resume restores history but never repeats a
  prompt automatically. Reconstructed tool history is available to Pi; the current
  prototype's activity panel only shows calls observed during this server run.
- erlexec owns a separate process group for Pi and cleans up that group on exit.
  Detached descendants that create their own groups are outside that guarantee;
  the deployment must handle whole-container shutdown.
- Demo and live histories are separate. Switching modes requires restarting the app.

## Runtime contract for the deployment repository

No Dockerfile or Compose file is included. The external deployment should build an
Elixir release after `mix deps.get`, `mix compile`, and `mix assets.copy`, install
Pi/Gentle and required development tools, and provide persistent mounts.
Set `PHX_SERVER=true` when starting the release (`bin/session_desk start`).

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.copy
MIX_ENV=prod mix release
```

| Variable | Default | Purpose |
|---|---|---|
| `SESSION_DESK_MODE` | `demo` | `demo` or `live` |
| `WORKSPACE` | Current directory | Agent working directory, as seen inside the container |
| `DATA_DIR` | `./data` | Persistent app-owned session files |
| `PI_EXECUTABLE` | `pi` | Executable path or command on PATH |
| `PI_CODING_AGENT_DIR` | Inherited Pi default | Configured agent home |
| `PI_ARGS_JSON` | `[]` | Additional CLI arguments as a JSON string array |
| `BIND` | `127.0.0.1` | Set `0.0.0.0` inside a container |
| `PORT` | `4000` | HTTP listener |
| `PHX_SERVER` | Unset | Set `true` to enable HTTP when starting a release |
| `APP_ORIGIN` | `http://localhost:4000` | Exact browser origin, including scheme/port, for LiveView |
| `SECRET_KEY_BASE` | Development-only value | Required in production, at least 64 bytes |

Run as the deployment's unprivileged application user. Preserve the data directory,
agent home, and project mount. Forward WebSockets through the authenticated reverse
proxy. `GET /health` checks the web service, not model/provider health. Browser
CSRF and origin checks remain enabled even though login is external. Never expose
the application port around the authenticating proxy.

## Tests

```sh
mix check
```

The ExUnit suite covers LF-only framing, real Gentle-shaped snapshots, streaming
projections, subscriber disconnect/reconnect, question validation, and abort.
When `PI_TEST_RUNTIME` points at the installed test dependencies below, it also
tests the Elixir controller against real Pi/Gentle, including process interruption
and saved-history recovery: `PI_TEST_RUNTIME=../runtime-check mix check`.

To verify **real Pi + real Gentle tools** without credentials, install test runtimes
outside this project and run the deterministic provider integration:

```sh
npm install --prefix ../runtime-check --ignore-scripts \
  @earendil-works/pi-coding-agent@1.4.0 gentle-pi@4.3.0
PI_TEST_RUNTIME=../runtime-check node test/support/pi_smoke.mjs
```

This test loads only Gentle Todo and Gentle's questionnaire extension into real Pi.
It does not validate the entire Gentle harness or a hosted model. The temporary
provider runs a fixed sequence: write tasks → ask question → mark tasks done →
stream final text. It is never enabled in normal live mode.

`test/support/browser_check.mjs` is an optional Playwright check for a running server.
Set `PLAYWRIGHT_MODULE` to an installed Playwright module, `TEST_BASE_URL` if needed,
and `TEST_LIVE_PI=1` when the server uses the deterministic provider above. It checks
desktop and mobile flows, including closing the browser while a question is pending.

## Structure

- `lib/session_desk/session.ex`: subprocess ownership, RPC commands, pending dialogs,
  startup history hydration, and throttled broadcasts.
- `lib/session_desk/state.ex`: browser-facing projection of Pi/Gentle events.
- `lib/session_desk/protocol.ex`: bounded, strict LF-delimited JSON framing.
- `lib/session_desk_web/desk_live.ex`: LiveView page and actions.
- `priv/static/`: CSS and small browser helpers; Phoenix bundles are copied locally
  by `mix assets.copy`. No frontend npm build or CDN dependency.
- `priv/demo_agent.mjs`: explicitly scripted demo transport.

## Integration references

- https://pi.dev/docs/latest/rpc
- https://pi.dev/docs/latest/rpc-extension-ui
- https://github.com/Gentleman-Programming/gentle-shell/blob/v4.3.0/extensions/gentle-todo.ts
- https://github.com/Gentleman-Programming/gentle-shell/blob/v4.3.0/lib/shell-todo.ts
- https://github.com/Gentleman-Programming/gentle-shell/blob/v4.3.0/lib/rpc-host.ts

Implementation status and executed checks are recorded in `VALIDATION.md`.
