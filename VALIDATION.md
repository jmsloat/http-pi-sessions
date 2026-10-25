# Prototype validation

## Passed

- Real Pi 1.4.0 + Gentle 4.3.0 deterministic-provider integration: two complete
  Gentle Todo snapshots, a real `ask_user_question` RPC dialog answered with `Yes`,
  persisted Gentle state in Pi history, and streaming assistant events.
- Source inspection found that Pi 1.4.0 sends text deltas without the full message
  on `message_update`; the projection supports that format and older full-message
  updates.

- Phoenix compilation: successful on Elixir 1.18.4 / Erlang OTP 27.3.4.14.
- `PI_TEST_RUNTIME=../runtime-check mix check`: **11 tests, 0 failures**, including
  the Elixir controller driving real Pi/Gentle, intentional Pi termination,
  reopening persisted history, no duplicate prompt, and no stale dialog.
- Formatting checks passed.

- Chromium browser checks passed in **both scripted demo and real Pi/Gentle modes**:
  desktop layout, streaming, page reload, closing/reopening the browser context,
  pending question restoration, answer submission, completed task updates, no
  duplicate prompt, no mobile horizontal overflow, and no browser JavaScript errors.
- Desktop and mobile screenshots visually inspected. Screenshots are QA artifacts,
  not part of the source repository.
- Browser testing caught and fixed a LiveView button-value collision that could
  submit an empty answer; the regression is covered by the LiveView test.

## Not tested

- User's configured model/provider credentials and full Gentle installation.
- External Docker/Compose/reverse-proxy deployment.
- Extended sessions, load, detached tool subprocesses, and browser IDE features.
