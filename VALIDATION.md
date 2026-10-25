# Validation — session management milestone (0.2.0)

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
  further work. Preview/diff panels and worktrees are not part of this milestone.
