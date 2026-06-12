# Ark Terminal Sub-Project Plan

## Purpose

Build an Ark-owned terminal console for interactive R that is faster, more
consistent, and more integrated than a raw `R` prompt, without degrading any
normal terminal behavior users already rely on.

The product target is not a toy wrapper around `R`. It is a real terminal
frontend that can replace the managed pane command in `ark.nvim` while keeping
script-buffer and console intelligence aligned through the same Ark LSP and live
R session bridge.

## Product Promise

Ark Terminal must feel like a normal Linux terminal running interactive `R`, plus
Ark-native language intelligence.

The user should get:

- normal R prompt behavior
- normal terminal output behavior
- normal paste, interrupt, resize, suspend, and EOF behavior
- normal behavior for help pagers, browser/debug prompts, readline prompts, and
  subprocesses
- Ark completions, completion docs, signature help, and object-aware context in
  the console input line
- the same runtime session that Neovim script buffers use
- no terminal scraping as the completion architecture

If Ark Terminal cannot preserve raw-terminal behavior for a scenario, it must
fall back to transparent PTY pass-through for that scenario instead of providing
a broken enhanced mode.

## Non-Negotiable Parity With Raw Terminal R

Ark Terminal is not acceptable until it preserves these behaviors compared with
running `R` directly in the same terminal.

### Terminal IO

- Preserve stdout and stderr ordering.
- Preserve ANSI SGR styling, cursor movement, carriage returns, line clearing,
  alternate screen use, bracketed paste, and terminal title sequences.
- Preserve UTF-8, wide characters, combining marks, and grapheme-aware cursor
  movement in the Ark-owned input line.
- Resize the child PTY on host terminal resize and propagate `SIGWINCH`.
- Preserve `$TERM`, terminal size, locale, color-related environment, and tty
  identity expected by child processes.
- Avoid repaint flicker during normal R output, progress bars, and completion
  popup open/close.

### Input Semantics

- `Enter` submits complete input.
- Multiline R input keeps normal continuation behavior.
- `Ctrl-C` interrupts the child R process.
- `Ctrl-D` sends EOF when the input line is empty and deletes forward when it is
  not empty, matching common readline behavior.
- `Ctrl-Z` suspends or delegates consistently with terminal expectations.
- Arrow keys, Home, End, Delete, Backspace, word movement, kill/yank, and reverse
  history search work at least as well as common readline defaults.
- Bracketed paste handles multiline code without accidental partial execution.
- Raw byte input can be passed through when Ark Terminal is not at an editable R
  prompt.

### R-Specific Interactive Behavior

- Top-level prompts `>` and continuation prompts `+` work.
- `browser()` prompts work.
- `debug()`, `recover()`, and nested evaluation prompts work.
- `readline()`, `menu()`, `utils::select.list(graphics = FALSE)`, and package
  prompts work.
- `help()`, `?topic`, `??topic`, `example()`, and pager output behave normally.
- Long-running R output, progress bars, warnings, messages, and errors render
  correctly.
- Child terminal programs launched from R, for example `system("vim")`,
  `system("less")`, or package install prompts, must enter transparent
  pass-through if enhanced prompt mode cannot safely own input.

### Session Behavior

- `.Rhistory` and normal R startup/shutdown behavior are not silently broken.
- `.Rprofile`, project startup hooks, and user library paths behave as they do
  in the current managed launcher.
- Ark's private bridge library path may be used during bootstrap, but the user's
  normal `.libPaths()` must be restored before the interactive prompt.
- Existing Ark readiness concepts remain distinct:
  - bridge ready: IPC service answers Ark requests
  - REPL ready: prompt is stable and safe for send-style workflows

## Architecture

Ark Terminal should be added inside this repository first, as an Ark-owned
binary with a clean CLI and protocol boundary that can be split into a separate
repo later if it becomes generally useful outside `ark.nvim`.

Target workspace shape:

```text
crates/ark-terminal/
  src/main.rs
  src/app.rs
  src/pty.rs
  src/input.rs
  src/lsp_client.rs
  src/completion.rs
  src/prompt.rs
  src/session.rs
  src/ipc.rs
  src/render.rs
  tests/
```

Expected runtime shape:

```text
host terminal or tmux pane
  -> ark-terminal
      -> child R process in a PTY
      -> arkbridge loaded in that child R process
      -> ark-lsp over stdio or local process transport
      -> optional Ark Terminal local IPC for Neovim control
```

The console input line should be represented as a normal R document from the LSP
point of view:

```text
ark-console://<session-id>/input.R
```

Ark Terminal owns edits to that document and sends:

- `initialize`
- `textDocument/didOpen`
- incremental `textDocument/didChange`
- `textDocument/completion`
- `completionItem/resolve`
- `textDocument/signatureHelp`
- optional hover/help requests

The same `ark-lsp` completion planner and detached session bridge used by
Neovim buffers must serve the console. Blink is not involved; Ark Terminal
renders its own menu.

## Design Principles

- Prefer PTY pass-through over emulating R incorrectly.
- Intercept only the editable prompt/input region.
- Keep completion intelligence in `ark-lsp`, not in the terminal frontend.
- Keep live R inspection behind `arkbridge`, not terminal scraping.
- Make prompt state explicit and testable.
- Keep Neovim integration as a client of Ark Terminal, not a second
  implementation of terminal semantics.
- Use proven terminal and PTY libraries where they fit. Do not hand-roll a VT
  parser or line editor unless the available crates fail the parity bar.

## Core Components

### PTY Supervisor

Responsibilities:

- spawn child `R` with the same launcher semantics Ark uses today
- create and resize the child PTY
- forward child output to the host terminal
- forward raw input when enhanced mode is disabled
- manage child lifecycle and exit status
- deliver interrupts and EOF correctly
- expose structured state to the rest of Ark Terminal

Implementation notes:

- Evaluate `portable-pty` and `nix::pty` during the spike.
- Keep the supervisor independent from rendering so it can be tested with
  scripted PTY sessions.
- Treat output as a byte stream. Decode for prompt detection and screen model
  only after preserving raw output forwarding.

### Prompt State Machine

Responsibilities:

- detect top-level, continuation, browser, debug, recover, and other known R
  prompt states
- distinguish editable prompt mode from raw pass-through mode
- know when a prompt is stable enough for Ark completions
- avoid confusing printed strings that look like prompts with real prompts

Implementation notes:

- Prefer explicit cooperation from the launcher or `arkbridge` when possible.
  Prompt markers or status events are better than heuristics.
- Heuristics may be used as fallback, but must be covered by transcript tests.
- State transitions should be logged at trace level for diagnosing stuck input.

### Line Editor

Responsibilities:

- own the input buffer while at an editable R prompt
- support multiline R expressions
- support normal editing keys and history search
- keep a virtual LSP document synchronized with the input buffer
- apply LSP completion edits exactly
- submit complete code to the child PTY

Implementation notes:

- Evaluate `reedline`, `rustyline`, and a small custom editor built on
  `crossterm`.
- Choose the option that best supports async completion menus, signature help,
  multiline input, and exact LSP text edits.
- If a library cannot preserve terminal parity, use it only for editor logic and
  keep PTY/output handling Ark-owned.

### Completion UI

Responsibilities:

- request completion from `ark-lsp`
- render completion items without using Blink
- support trigger characters already advertised by Ark:
  `$`, `@`, `:`, `(`, `[`, `,`, space, `"`, `'`, and `/`
- support manual completion
- support item docs/details through `completionItem/resolve`
- support snippet-like insert text only when Ark Terminal can apply it exactly
- never block typing on slow runtime inspection

Acceptance behavior:

- `$`, `@`, namespace, call argument, subset, string subset, comparison string,
  package string, file path, and `{targets}` completions match Neovim's Ark LSP
  behavior.
- If the bridge is not ready, static completions remain available and runtime
  completions degrade explicitly.
- Empty handled runtime contexts do not fall through to unrelated suggestions.

### Signature Help And Docs

Responsibilities:

- show signatures while typing calls
- update active parameter on `,` and `=`
- show compact docs for selected completion items
- provide an explicit command/keybinding to open full R help through Ark

Acceptance behavior:

- Signature help matches script-buffer behavior for common R functions,
  namespaced calls, and live-session formals.
- Documentation rendering is readable in narrow panes and does not corrupt the
  terminal scrollback.

### History

Responsibilities:

- preserve normal R history expectations
- provide fast console history search
- avoid duplicating or losing commands between Ark Terminal and R history

Implementation notes:

- Decide whether Ark Terminal writes history itself, delegates to R, or mirrors
  into R history after submit.
- The decision must be tested against `.Rhistory`, project startup, and multiple
  Ark sessions.

### Neovim Control IPC

Responsibilities:

- let `ark.nvim` start, stop, restart, interrupt, and query Ark Terminal
- let Neovim send code without relying exclusively on tmux paste
- expose readiness, child PID, session ID, bridge status, and current prompt
  state
- keep `vim-slime` / `nvim-slimetree` compatibility during transition

Possible commands:

```text
status
execute
interrupt
paste
focus
shutdown
resize
```

This IPC is separate from the R `arkbridge` IPC. Ark Terminal IPC controls the
frontend process. `arkbridge` answers R runtime intelligence requests.

## CLI Contract

Initial CLI target:

```sh
ark-terminal \
  --ark-lsp /path/to/ark-lsp \
  --status-dir /path/to/ark-status \
  --session-id <id> \
  --backend tmux \
  -- R --quiet
```

Requirements:

- Everything after `--` is the child command.
- The default child command should match the current managed launcher's R
  behavior.
- `--raw` starts transparent pass-through mode for diagnosis.
- `--no-lsp` starts a normal enhanced terminal without Ark completions for
  isolation.
- `--trace-log <path>` writes structured frontend diagnostics.
- `--print-status-json` prints startup metadata for test harnesses.

## Integration With Existing Ark.nvim

Phase the integration behind configuration:

```lua
require("ark").setup({
  session = {
    console_frontend = "ark-terminal",
  },
})
```

Migration path:

1. Keep raw managed `R` as the default.
2. Add an opt-in Ark Terminal launcher path.
3. Make Ark health checks report Ark Terminal availability.
4. Add E2E coverage for both raw R and Ark Terminal.
5. Switch the recommended managed pane command only after parity tests and real
   config smoke tests pass.
6. Keep a raw-R fallback for at least one release cycle after switching the
   recommendation.

## Milestones

### M0: Spike And Decision Record

Goal: prove the substrate is viable before product work begins.

Tasks:

- compare PTY crates and terminal input/rendering crates
- prototype child R PTY spawn, resize, output forwarding, and interrupt
- prototype prompt detection with transcript logging
- prototype one manual LSP completion request against `ark-lsp`
- measure raw overhead versus direct `R`
- write a decision note summarizing chosen libraries and rejected approaches

Exit criteria:

- child R behaves normally for basic input/output
- `Ctrl-C`, resize, paste, and EOF work in the prototype
- a manual completion request returns Ark items for `mtcars$`
- no architectural blocker is found for prompt-owned completions

### M1: Transparent Terminal Parity

Goal: Ark Terminal can be used as a normal terminal wrapper around `R` without
enhanced completions.

Tasks:

- add `crates/ark-terminal`
- implement child PTY supervisor
- implement raw pass-through mode
- implement resize, signal, EOF, and exit handling
- preserve environment and launcher bootstrap behavior
- add transcript-based tests for raw R interaction

Exit criteria:

- raw pass-through mode is not materially worse than `R` in a normal terminal
- common R output, help, pager, install prompt, and child process scenarios work
- Ark.nvim can launch Ark Terminal in raw mode as the managed pane

### M2: Prompt-Owned Line Editor

Goal: enhanced mode owns the editable R input line only when it is safe.

Current implementation status:

- prompt-state detection, key decoding, line editing, history navigation,
  bracketed paste, multiline submit, display-width-aware local rendering, and
  reverse history search are implemented for direct non-raw `ark-terminal` runs
- browser/debug-style prompts currently use safe pass-through fallback
- direct real-R transcript tests cover enhanced top-level input, local multiline
  rendering/submission, `browser()` pass-through, and `debugonce()` pass-through
- direct real-R transcript tests cover pass-through for `readline()`, `menu()`,
  `utils::select.list(graphics = FALSE)`, and text help output
- direct real-R transcript tests cover package install prompt pass-through using
  a temporary read-only library and offline repository
- direct real-R transcript tests cover child shell prompts and an interactive
  `less -X` pager launched through `system()`
- renderer unit tests cover exact right-margin autowrap and wide-grapheme wrap
  boundaries for local redraw/clear behavior
- the Neovim frontend wrapper now supports explicit enhanced mode via
  `ark_terminal.raw = false`; the repo default remains raw unless configured
  otherwise
- the user's full Neovim config is wired to launch the managed tmux R pane
  through release `ark-terminal` enhanced mode with a stable trace log
- batched enhanced input now compacts intermediate redraws so send-style
  workflows do not redraw once per byte; release benchmarking showed parity
  with raw PTY mode on a 1000-command batch workload

Tasks:

- implement prompt state machine
- implement top-level and continuation input editing
- implement multiline submit
- implement history navigation and reverse search
- implement bracketed paste behavior
- implement browser/debug prompt handling or safe pass-through fallback

Exit criteria:

- top-level R input feels at least as good as readline for daily use
- multiline paste does not accidentally execute partial fragments
- browser/debug prompts are either enhanced correctly or transparently passed
  through
- trace logs explain every enhanced/pass-through transition

### M3: Ark LSP Completion

Goal: console completions match script-buffer Ark completions.

Current implementation status:

- `crates/ark-terminal/src/lsp_client.rs` provides the tested protocol substrate
  for console documents: `ark-console://<session-id>/input.R` URI creation,
  full-document `didOpen` / `didChange` notifications, initialize/completion/
  resolve request construction, Content-Length JSON-RPC framing, completion
  response item extraction, and UTF-16 LSP text edit application
- the substrate is not yet connected to the enhanced terminal runtime or a live
  `ark-lsp` child process

Tasks:

- start or connect to `ark-lsp`
- maintain `ark-console://<session-id>/input.R`
- synchronize line-editor edits to LSP document changes
- request completions on manual invocation and trigger characters
- apply LSP text edits and insert text accurately
- implement completion item resolve
- dedupe and rank display consistently with Ark LSP responses

Exit criteria:

- console `mtcars$`, `mtcars[[`, `library("`, `pkg::`, function-call, file-path,
  comparison-string, and target-name completions match direct LSP requests
- completion latency is acceptable under cold, warm, bridge-ready, and
  bridge-unavailable states
- no R-process self-call deadlock is possible because completion is requested
  from the external frontend while R is idle

### M4: Signature Help, Docs, And Help Integration

Goal: the console has the same practical language-assistance surface as script
buffers.

Tasks:

- implement signature help popup/panel
- implement completion docs/details panel
- implement full help command integration
- implement narrow-pane layout rules
- implement keyboard navigation between input, menu, docs, and output

Exit criteria:

- signatures update while typing calls
- docs do not corrupt output or scrollback
- full help can open in the normal Ark help flow or in a terminal-safe pager

### M5: Neovim Managed-Pane Integration

Goal: Ark.nvim can use Ark Terminal as a first-class managed pane frontend.

Tasks:

- add Ark Terminal discovery/build support
- add session config for `console_frontend`
- add health checks
- wire readiness status into existing `bridge_ready` and `repl_ready` semantics
- expose Ark Terminal IPC through Lua session backend helpers
- preserve `vim-slime` / `nvim-slimetree` sends during transition
- add raw-R fallback on startup failure

Exit criteria:

- existing managed-pane workflows work with Ark Terminal enabled
- closed-pane restart, send-target revalidation, Ark tabs, help, ArkView, and
  targets workflows still work or have explicit documented limitations
- raw managed R remains available for rollback

### M6: Hardening And Performance

Goal: make Ark Terminal competitive with, and preferably faster than, radian for
the Ark.nvim workflow.

Tasks:

- add keypress latency benchmarks
- add completion latency benchmarks
- add startup overhead benchmarks
- add long-output and progress-bar stress tests
- fuzz LSP edit application and terminal input editing
- add stuck-state watchdog diagnostics
- verify memory use over long sessions

Performance targets:

- idle keypress p95 under 8 ms in enhanced mode
- warm completion menu p95 under 50 ms when no live bridge request is needed
- warm bridge-backed completion p95 under 120 ms for common object inspection
- no more than 150 ms median startup overhead compared with the existing managed
  raw-R launcher after dependencies are warm
- no visible output corruption during 10,000-line output stress tests

These are initial targets and should be replaced with measured baselines once
M0 and M1 exist.

### M7: Default Recommendation

Goal: decide whether Ark Terminal should become the recommended managed pane.

Tasks:

- run full E2E suite with raw R and Ark Terminal
- run real-config smoke tests
- run manual terminal emulator matrix
- document rollback path
- update README and SPEC if recommending Ark Terminal by default

Exit criteria:

- no known daily-use regression compared with raw terminal R
- Ark Terminal has clear advantages in console completion, docs, signatures,
  startup coordination, and Neovim control
- raw-R fallback remains documented and tested

## Verification Matrix

### Automated Tests

- Rust unit tests for input editing, LSP text edit application, prompt state, and
  completion request construction.
- PTY integration tests with scripted R sessions.
- Golden transcript tests for prompt transitions and pass-through behavior.
- Headless Neovim tests for managed-pane startup and status.
- tmux-backed E2Es for send-code, restart, Ark tabs, help, ArkView, and targets.
- Direct LSP completion parity tests comparing console document requests with
  normal script-buffer requests.
- Stress tests for long output, progress bars, paste, resize, interrupts, and
  repeated completion triggers.

### Manual Smoke Tests

Run in at least:

- tmux pane
- plain terminal outside tmux
- Neovim terminal backend
- narrow terminal
- wide terminal

Use at least:

- foot
- Alacritty or Kitty
- xterm-compatible fallback if available

Manual scenarios:

- start and quit R
- run long output
- run warnings and errors
- run `help(lm)` and `?lm`
- run `browser()` and inspect locals
- interrupt `Sys.sleep(30)`
- paste multiline code
- resize during output
- launch `system("less --help")` or equivalent pager-like subprocess
- complete `$`, `[[`, strings, package names, function arguments, and paths
- run ArkView from Neovim against the same session

## Risks And Design Responses

Risk: prompt detection is brittle.

Response: prefer explicit bridge/launcher prompt-state events, keep heuristics
as fallback, and enter pass-through when state is uncertain.

Risk: terminal rendering becomes worse than a raw terminal.

Response: forward raw PTY output to the host terminal wherever possible and draw
Ark UI overlays conservatively. Do not build a full terminal emulator unless
forced by a proven requirement.

Risk: line editing is not as good as readline.

Response: set readline parity as an M2 exit criterion and keep raw pass-through
fallback. Do not ship enhanced mode as default until daily editing is better
than raw R for the Ark workflow.

Risk: completion requests deadlock with the R bridge.

Response: Ark Terminal requests completions externally while R is idle at the
prompt. Avoid R readline hooks that synchronously call Ark LSP and then call
back into the same R process.

Risk: scope grows into a general terminal emulator.

Response: the product is an R console frontend. It must preserve terminal
behavior, but its enhanced features are scoped to R prompt input and Ark
language intelligence.

Risk: Ark Terminal and Neovim script buffers drift.

Response: keep completion planning in `ark-lsp` and add parity tests that run
the same completion contexts through script-buffer and console-document paths.

## Explicit Non-Goals For V1

- replacing `nvim-slimetree`
- replacing `vim-slime` before a better Ark Terminal IPC send path is proven
- remote SSH or multi-host sessions
- Windows support
- notebook UI
- Jupyter kernel behavior
- Positron comm surfaces
- plots pane, variables pane, or data explorer replacement beyond existing
  ArkView integration
- implementing a general-purpose terminal emulator for arbitrary shells

## Definition Of Done

Ark Terminal is product-ready when:

- it can be the managed pane frontend for normal Ark.nvim R work
- users do not lose normal terminal R behavior
- console completions are served by Ark LSP and match script-buffer semantics
- live runtime completions use the same managed R session bridge
- completion, docs, signatures, paste, history, interrupt, resize, and help are
  covered by automated tests and manual smoke checks
- performance is measured and within the targets above or the targets have been
  updated with justified baselines
- raw managed R remains available as a documented fallback
