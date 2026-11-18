local ark_test = require("ark_test")
local tmp = ark_test.run_tmpdir()
local repo = vim.env.ARK_REPO_ROOT
local trace = tmp .. "/math-trace.jsonl"
local path = tmp .. "/equation.qmd"
local init = vim.env.ARK_TEST_NVIM_INIT
if init == "NONE" then
  init = repo .. "/tests/e2e/init.lua"
end
local session = ark_test.register_tmux_session(ark_test.tmux_session_name("math_completion"))
local shellescape = vim.fn.shellescape
vim.fn.writefile({ "Agreement: $x$." }, path)

local function observed(predicate)
  if vim.fn.filereadable(trace) ~= 1 then
    return false
  end
  for _, line in ipairs(vim.fn.readfile(trace)) do
    local ok, event = pcall(vim.json.decode, line)
    if ok and predicate(event) then
      return true
    end
  end
  return false
end

local pane = vim.trim(ark_test.tmux({
  "new-session", "-d", "-P", "-F", "#{pane_id}", "-s", session,
  table.concat({
    "env -u ARK_TMUX_ANCHOR_PANE -u ARK_TMUX_SESSION",
    "ARK_TUI_TRACE_LOG=" .. shellescape(trace),
    "nvim -n -i NONE -u " .. shellescape(init),
    shellescape(path),
    "-c " .. shellescape("luafile " .. repo .. "/tests/e2e/tui_blink_trace.lua"),
  }, " "),
}))

local function send(...)
  ark_test.tmux(vim.list_extend({ "send-keys", "-t", pane }, { ... }))
end

ark_test.wait_for("Blink trace", 15000, function()
  return observed(function(event) return event.label == "loaded" end)
end)
ark_test.wait_for("Ark LSP in Quarto", 15000, function()
  if observed(function(event)
    return event.label == "ArkTraceSnapshot" and event.ark_clients > 0 and event.ark_status.lsp_available
  end) then
    return true
  end
  send("Escape", ":ArkTraceSnapshot ready", "Enter")
  return false
end)

local function type_and_accept(input, typed, accepted)
  send("-l", input)
  ark_test.wait_for("automatic Ark math completion in Blink", 5000, function()
    return observed(function(event)
      if event.label ~= "BlinkCmpShow" or not event.menu_open or event.line ~= typed
        or not event.trigger or event.trigger.initial_kind == "manual" then
        return false
      end
      for _, item in ipairs(event.items or {}) do
        local from_lsp = item.source_id == "lsp" or item.source_id == "ark_lsp"
        if item.label == "\\kappa" and from_lsp and item.client_name == "ark_lsp" then
          return true
        end
      end
      return false
    end)
  end)
  send("C-y")
  ark_test.wait_for("accepted TeX command", 5000, function()
    return observed(function(event)
      return event.label == "TextChangedI" and event.line == accepted
    end)
  end)
end

-- Replace the command before an existing closing dollar, or add a missing one.
send("Escape", "$", "h", "i")
type_and_accept([[ + \kap]], [[Agreement: $x + \kap$.]], [[Agreement: $x + \kappa$.]])
send("Escape", ":call setline(1, 'Reliability: $')", "Enter", "$", "a")
type_and_accept([[\kap]], [[Reliability: $\kap]], [[Reliability: $\kappa$]])

ark_test.tmux({ "kill-session", "-t", session })
