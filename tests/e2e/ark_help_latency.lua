vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = vim.g.mapleader or " "

local ark_test = dofile("tests/e2e/ark_test.lua")
local perf = require("perf")
local stop_watchdog = ark_test.start_watchdog(60000, "ark_help_latency")
local socket = assert(vim.env.ARK_TMUX_SOCKET)
local session = assert(vim.env.ARK_TMUX_SESSION)
local pane = assert(vim.env.ARK_TMUX_ANCHOR_PANE)
local output = ""

-- A real tmux client in an isolated PTY: measure terminal output, not just
-- the asynchronous display-popup dispatch. No desktop window is mapped.
local job = vim.fn.jobstart({ "tmux", "-S", socket, "attach-session", "-t", session }, {
  pty = true,
  width = 120,
  height = 45,
  env = { TERM = "xterm-256color", TMUX = "" },
  on_stdout = function(_, data)
    output = output .. table.concat(data, "\n")
  end,
})
assert(job > 0)
ark_test.wait_for("attached client", 5000, function()
  return ark_test.tmux({ "list-clients" }) ~= ""
end)

local ark = require("ark")
ark.setup({ auto_start_pane = false, auto_start_lsp = false, keymaps = true, help = { display = "tmux_popup" } })
vim.cmd("edit " .. vim.fn.fnameescape(ark_test.run_tmpdir() .. "/help-latency.R"))
vim.bo.filetype = "r"
local source = vim.api.nvim_get_current_buf()
local lsp_config = ark.lsp_config(source)
ark_test.assert_fresh_detached_lsp_binary(lsp_config.cmd[1])
ark.start_lsp(source)
ark_test.wait_for("initialized LSP and baseline metadata", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = source, name = "ark_lsp" })[1]
  if not client or not client.initialized then
    return false
  end
  local status = ark.status({ include_lsp = true }).lsp_status
  local baseline = status and status.detachedBaselineStatus
  return baseline and baseline.lastBootstrapSuccessMs ~= nil and not baseline.pending
end)

vim.env.TMUX = socket .. ",0,0"
vim.env.TMUX_PANE = pane
local help_key = vim.fn.maparg(vim.g.mapleader .. "r?", "n", false, true)
assert(type(help_key.callback) == "function", "expected the real <leader>r? mapping")

local cases = {
  { "lm", "Fitting Linear Models" },
  { "mean", "Arithmetic Mean" },
  { "utils::head", "Return the First or Last Parts of an Object" },
}
local results = {}
for _, mode in ipairs({ "static", "live" }) do
  if mode == "live" then
    assert(ark.start_pane())
    ark_test.wait_for("live bridge", 20000, function()
      return ark.status().bridge_ready == true
    end)
    ark_test.wait_for("live REPL", 10000, function()
      return ark.status().repl_ready == true
    end)
  end
  local samples = {}
  -- Different topics first, then repeats: no rendered-page cache may hide
  -- the cost of navigating to documentation the user has not opened yet.
  for _ = 1, 2 do
    for _, case in ipairs(cases) do
      vim.api.nvim_set_current_buf(source)
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { case[1] })
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.wait(150, function()
        return false
      end) -- let didChange reach the server
      output = ""
      local start = vim.uv.hrtime()
      help_key.callback()
      assert(
        vim.wait(5000, function()
          return output:find(case[2], 1, true) ~= nil
        end, 1),
        "help never became visible: " .. case[1]
      )
      local ms = (vim.uv.hrtime() - start) / 1e6
      samples[#samples + 1] = ms
      perf.record("help." .. mode .. ".visible", ms, {
        test = "ark_help_latency.lua",
        condition = mode .. " real tmux popup, including viewer startup",
        fixture = case[1],
      })
      ark_test.tmux({ "display-popup", "-C" })
      vim.wait(100, function()
        return false
      end)
    end
  end
  results[mode] = samples
end
vim.fn.jobstop(job)
stop_watchdog()
vim.print({ help_latency_ms = results })
for mode, samples in pairs(results) do
  table.sort(samples)
  assert(samples[4] <= 120, mode .. " help key-to-visible median exceeds 120ms: " .. vim.inspect(samples))
  assert(samples[#samples] <= 200, mode .. " first help popup exceeds 200ms: " .. vim.inspect(samples))
end
