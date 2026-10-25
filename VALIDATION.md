# Validation — workspace previews milestone (0.3.0)

## Current milestone

- Elixir 1.18.4 / Erlang OTP 27.3.4.14 compilation with warnings treated as errors.
- `PI_TEST_RUNTIME=../runtime-check mix check`: **35 tests, 0 failures**, including
  the existing real Pi 1.4.0 / Gentle 4.3.0 deterministic-provider integration.
- New backend coverage: text/image/empty/binary/oversized files, directory limits,
  traversal and symlink rejection, special files, missing paths, staged/unstaged
  and deleted files, spaces/glob characters/newlines in names, unborn repositories,
  nested workspace scoping, Git output/line limits, and unchanged Git index contents.
  External diff, textconv, and fsmonitor helpers are not invoked by the inspector.
- New LiveView coverage: escaped HTML source, colored diff output, refresh after
  external edits and file deletion, refresh on agent completion, stopped-agent
  inspection, and resetting preview/folder state on workspace/session switching.
- Chromium checks passed at 1440×1000 and 390×844: separate staged/unstaged patches,
  escaped HTML, image decoding, untracked previews, external edit refresh, workspace
  isolation, no horizontal page overflow, and no browser JavaScript errors.
  Desktop/mobile screenshots were visually inspected; selected previews are placed
  before the lists and brought into view without moving focus on automatic refresh.
- Production release built and started; the file/diff browser checks also passed
  against the release using disposable demo data.
- No database migration, Docker/Compose, or reverse-proxy changes are required.
  The deployment image needs Git for the changes panel.

## Current limits

- Previews show current workspace content, not historical per-session artifacts.
  Refresh occurs on the selected agent returning to idle or by clicking Refresh;
  no filesystem watcher is installed.
- Text is escaped source (including Markdown/HTML/SVG), not a rendered website.
  PNG/JPEG/GIF/WebP are supported; other binary formats are not previewed.
- Lists display at most 500 entries; text/image limits are 256 KiB/2 MiB, and Git
  commands allow five seconds/1 MiB with at most 5,000 rendered diff lines.
- Renames appear as deletion/addition; submodule changes are excluded. No editing,
  staging, resetting, committing, historical diffs, or worktree creation.
- Workspaces are trusted coding-agent checkouts. Path checks reject traversal,
  symlinks below the root and special files, but are not an OS isolation boundary
  against concurrent filesystem replacement. Git can still apply repository clean
  filters configured by the user; this is not execution isolation for untrusted repos.
- The hosted provider/full Gentle configuration and external server deployment
  have not been exercised here. Existing session-history and operational limits below
  continue to apply.

# Previous milestone — session management (0.2.0)

## Passed

- Elixir 1.18.4 / Erlang OTP 27.3.4.14 compilation with warnings treated as errors.
- Production release built and started successfully: HTTP health, saved-session
  page, and SQLite initialization verified with `PHX_SERVER=true`.
- `PI_TEST_RUNTIME=../runtime-check mix check`: **25 tests, 0 failures**.
  - SQLite metadata persistence, archive/restore, original prototype history import,
    missing directory validation, and symlink workspace deduplication.
  - One agent per workspace, independent session transcripts, simultaneous agents
    in different workspaces, and no automatic replay after application restart.
  - Empty/thinking/tool-only turns stay hidden in saved, resumed, and streaming
    views; visible text and provider errors remain visible.
  - Multi-tab LiveView updates, stale event isolation, session creation/renaming,
    model controls, and question validation.
  - Sanitized Markdown/code blocks, active-branch history traversal, malformed
    cyclic history, strict RPC framing, Gentle Todo, streaming, and abort.
- Real Pi 1.4.0 and Gentle 4.3.0, with a deterministic test provider:
  - Actual `todo` and `ask_user_question` tools, streaming output, persisted history,
    process interruption, and reconnect/resume.
  - Available-model discovery, changing to a different reasoning model, thinking
    level changes, and effective-state confirmation.
  - Managed-session model/thinking persistence after an agent crash and catalog
    restart, despite conflicting default model arguments in `PI_ARGS_JSON`.
- Chromium browser checks passed in both demo and real Pi/Gentle modes:
  model/thinking controls, desktop/mobile layout, reload during a run, closing and
  reopening the browser while a question is pending, answering, task updates, and
  no duplicate prompt, horizontal overflow, or browser JavaScript errors.
- Additional browser coverage passed for workspace registration, session creation
  and switching, independent drafts, Markdown in old-format saved history, busy
  workspace exclusion, two-tab suspend/resume, archive/restore, persisted model
  choice, and mobile navigation.
- Desktop and mobile screenshots visually inspected (internal QA only).
- Browser testing caught and fixed restored drafts being cleared on a later patch,
  and expanded session settings collapsing during archive/restore.

## Limits

- The real Pi tests use a local deterministic provider, not hosted model inference.
  They load Gentle Todo and the questionnaire extension, not the entire Gentle
  harness. The user's configured provider credentials/full installation are untested.
- Deployment remains in the separate repository. No Docker or Compose changes.
- Extended sessions, load, overlapping directory workspaces, detached subprocess
  groups, compaction-summary previews, and unsupported native build targets need
  further work. Worktrees were not part of that milestone; preview/diff coverage is recorded above.
