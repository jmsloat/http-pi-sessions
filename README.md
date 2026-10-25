# Session Desk

A single-user, self-hosted coding-agent workspace in **Elixir + Phoenix LiveView**.
Pi owns conversation history; Gentle Shell owns todos and questions; SQLite stores
workspace/session metadata. Authentication and TLS belong to your reverse proxy.

The current milestone supports multiple existing-directory workspaces and saved
sessions, live provider/model and thinking controls, sanitized Markdown with fenced
code blocks, tool results, Gentle Todo, interactive questions, and reconnect/resume.
Workspace file previews and staged/unstaged Git diffs are available alongside the chat.
Worktrees and deployment configuration remain outside this milestone.

## Run the demo

Requirements: Elixir 1.18+, Erlang/OTP 27+, a C++ compiler and make (for erlexec),
and Node 22.19+ (also required by the tested Pi/Gentle versions).

```sh
mix local.hex --force
mix local.rebar --force
mix setup
mix phx.server
```

Open http://localhost:4000. Click **Resume session**, send a message, watch the plan
appear, refresh while the agent is working, and answer its question. **Demo mode is a scripted RPC
fixture, not a language model.** It performs no workspace operations. Its history
for the first session is stored in `data/demo.json`; subsequent sessions use
`DATA_DIR/sessions/demo/`.

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

The app starts Pi directly with `--mode rpc --session <app-owned-session-file>`.
The imported first live session keeps `DATA_DIR/pi-session.jsonl`; new ones use
`DATA_DIR/sessions/live/<id>.jsonl`.
It sets `GENTLE_SHELL_INTERACTIVE_HOST=1`, which enables Gentle's native RPC question
fallbacks. Optional `PI_ARGS_JSON` is a JSON array, for example
`["--provider","anthropic","--model","your-model-id"]`. Arguments are passed
directly to the process, not interpolated into a shell command.

Gentle must actually be loaded in that Pi home; selecting live mode alone does not
install it. Gentle's launcher may use a separate home or a bundled Pi executable,
so configure the paths from your own installation rather than assuming a location.

## Workspaces, sessions, and model controls

- **Add workspace** registers an existing directory visible inside the server or
  container. This does not clone a repository or create a worktree. Symlink aliases
  to an already registered directory are rejected.
- **New session** creates metadata only. Opening any saved session reads its history
  without launching Pi. Each session has a bookmarkable `/sessions/<id>` URL.
- **Resume session** explicitly starts its agent. Only one agent process can own a
  workspace at a time: resuming another session suspends an idle one, and rejects
  the action if that session is busy. Different workspaces can run concurrently.
- **Model** groups Pi's available models by provider. Choose one and click **Apply
  model** while idle. No environment edit or container restart is needed. Models
  and credentials come from the configured Pi agent home, not a hardcoded list.
- **Thinking** appears for reasoning models. Pi clamps unsupported levels to a
  supported value; the selector then displays the effective level reported by Pi.
- **Session settings** lets you rename, suspend, archive, or restore a session.
  Archive preserves its transcript and requires it to be idle/stopped.
- Model and thinking choices are remembered per session, including after restart.
  `PI_ARGS_JSON` model arguments are defaults for sessions without a recorded choice.
  The tested Pi RPC setters do not change your terminal's global model defaults.
- Drafts are independent per session and kept in browser-tab session storage.
  Workspaces and sessions are available on mobile through the navigation button.

## Files and changes

Open **Files & changes** beside the conversation. On desktop, the inspector expands
so you can read code and chat side by side; on mobile it appears above the conversation.
You can browse folders, preview UTF-8 source/text and PNG/JPEG/GIF/WebP images, and
inspect separate **Staged** (index vs HEAD) and **Unstaged** (files vs index) diffs.
Untracked files open their current contents. Renames appear as a deletion and an addition.
Deleted tracked files still have a diff even though their current-file preview is unavailable.
HTML, SVG, and Markdown are shown as escaped source; workspace content is never run
as a web page. Unsupported binary files show an explanation.

This is the **current workspace**, shared by all its sessions, not a historical
snapshot or a list of changes attributed to the selected agent. Files remain available
when an agent is stopped or a session is archived. The open panel refreshes when the
selected agent returns to idle; use **Refresh** for terminal edits, another session's
changes, or intermediate output during a run. Refresh also reloads the selected preview.

Reads run asynchronously. Each directory/change list displays at most 500 entries;
text previews allow 256 KiB and images 2 MiB. Git commands have a five-second deadline
and 1 MiB output limit; rendered diffs allow at most 5,000 lines. Larger diffs report that limit rather than displaying an
incomplete patch. Git must be installed for diffs; non-Git directories still support
file previews. Submodule contents are excluded from the changes list.

The inspector has no edit, stage, reset, or commit actions. It disables Git's optional
index refresh, fsmonitor, external diff, and textconv helpers. Paths are restricted to
the registered workspace; `.git`, symlinks within it, and special files cannot be
opened. The registered root itself may be a symlink. Workspaces are trusted server
checkouts used by the coding agent; these checks are not an OS sandbox against a
process concurrently replacing files or directories.

## Upgrading from the prototype

Stop the old app cleanly and back up the **entire `DATA_DIR`** before upgrading.
Keep its existing data and agent-home mounts. The first launch creates
`catalog.sqlite3` (schema version 1) and registers your configured `WORKSPACE`.
The first session points at the existing `pi-session.jsonl` or `demo.json`; it is
not moved, rewritten, or replayed. Click **Resume session** to start its agent.

`WORKSPACE` now seeds the first workspace; changing the environment later does not
move existing sessions to a new directory. Register additional directories in the UI.
Paths must remain valid inside the container after an upgrade. Demo/live metadata
and transcript files are separate; switching modes requires restarting the app.

Back up the whole data directory while the app is stopped (or use a consistent
SQLite backup plus transcript backups). SQLite WAL/SHM files may exist while running;
do not copy just `catalog.sqlite3` from a running app. Metadata migrations run at
startup, and newer unknown schema versions are rejected. There is no automatic
schema downgrade. The original prototype only understands its original single file.

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
- Agent messages render sanitized Markdown, with styled fenced code blocks.
  Tool activity is bounded to the last 100 calls;
  long-conversation pagination is not implemented yet.
- Pi persists history. Pending dialogs are only live process state and do not
  survive an agent/container restart. Resume restores history but never repeats a
  prompt automatically. Saved tool results reappear in the activity panel; their
  original call arguments are currently shown only for calls observed live.
- erlexec owns a separate process group for Pi and cleans up that group on exit.
  Detached descendants that create their own groups are outside that guarantee;
  the deployment must handle whole-container shutdown.
- Server restarts leave sessions stopped. Previously running work is marked
  interrupted. Pending questions do not survive agent restarts. Missing workspace
  mounts produce an actionable error instead of launching in a different directory.
- Offline previews show up to 500 saved messages and read files up to 32 MB. They
  follow the selected Pi JSONL branch; compaction summaries and custom entry types
  are not expanded in offline previews. Resume hydrates Pi's own current context.
  RPC records still have an 8 MB limit. Very large active sessions need further work.
- Separate registered directories should be independent checkouts. Overlapping
  directories inside one repository are not detected as a shared editing workspace.

## Runtime contract for the deployment repository

No Dockerfile or Compose file is included. The external deployment should build an
Elixir release after `mix deps.get`, `mix compile`, and `mix assets.copy`, install
Git, Pi/Gentle and required development tools, and provide persistent mounts.
SQLite and MDEx use native dependencies; builds download precompiled binaries on
supported platforms. Source builds need the corresponding C/Rust toolchains.
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
| `WORKSPACE` | Current directory | Initial workspace directory on first startup |
| `DATA_DIR` | `./data` | Persistent SQLite catalog and app-owned session files |
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

The ExUnit suite covers framing, Gentle state, streaming, model controls, sanitized
Markdown, SQLite persistence, legacy history, workspace exclusion, archive/restore,
independent sessions, multi-tab reconnect, question validation, and abort.
When `PI_TEST_RUNTIME` points at the installed test dependencies below, it also
tests the Elixir controller against real Pi/Gentle, including process interruption
model/thinking changes and saved-history recovery: `PI_TEST_RUNTIME=../runtime-check mix check`.

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
`session_browser_check.mjs` also exercises workspace/session UI and draft isolation;
its fixture expects an old-format demo history containing a fenced code block, an
initial workspace named `desk-browser-workspace`, and `TEST_WORKSPACE` pointing to
another existing directory. Use disposable data/workspace directories for these checks.

`test/support/files_browser_check.mjs` exercises staged/unstaged diffs, source and
image previews, refresh, workspace isolation, and mobile layout. Run it against a
**disposable demo server**: it registers temporary workspaces/sessions and removes
its fixture files afterward. It accepts the same Playwright/base URL variables.

## Structure

- `lib/session_desk/catalog.ex`: versioned SQLite catalog, process ownership,
  lifecycle, and workspace exclusion.
- `lib/session_desk/workspace.ex`: bounded file reads and read-only Git inspection.
- `lib/session_desk_web/file_panel.ex`: asynchronous file browser and preview/diff panel.
- `lib/session_desk/history.ex`: offline previews from existing Pi/demo transcripts.
- `lib/session_desk_web/markdown.ex`: Markdown rendering and HTML sanitization.
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
