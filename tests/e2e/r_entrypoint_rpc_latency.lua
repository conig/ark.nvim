vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local perf = require("perf")
local stop_watchdog = ark_test.start_watchdog(30000, "r_entrypoint_rpc_latency")

local function elapsed_ms(start_ns)
  return math.floor((vim.uv.hrtime() - start_ns) / 1e6)
end

local function median(values)
  local copy = vim.deepcopy(values)
  table.sort(copy)
  return copy[math.floor(#copy / 2) + 1]
end

local function labels(values)
  return table.concat(vim.tbl_map(tostring, values), ",")
end

local function assert_budget(label, values, max_ms)
  local value = median(values)
  if value > max_ms then
    ark_test.fail(label .. " median dispatch took " .. tostring(value) .. "ms, expected <= " .. tostring(max_ms) .. "ms; samples=" .. labels(values))
  end
  return value
end

local ark = require("ark")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  configure_slime = false,
  view = {
    display = "tmux_popup",
  },
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, "/tmp/r_entrypoint_rpc_latency.R")
vim.bo[source_buf].filetype = "r"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "lm", "mtcars" })

local samples = {
  parent_help = {},
  parent_view = {},
  console_help = {},
  console_view = {},
}
local current_label = nil
local current_start = nil

local original_help_topic = ark.help_topic
local original_view = ark.view

ark.help_topic = function(topic, bufnr)
  samples[current_label][#samples[current_label] + 1] = elapsed_ms(current_start)
  return topic, nil
end

ark.view = function(expr, bufnr)
  samples[current_label][#samples[current_label] + 1] = elapsed_ms(current_start)
  return true, nil
end

local function measure(label, fire)
  for _ = 1, 7 do
    local expected = #samples[label] + 1
    current_label = label
    current_start = vim.uv.hrtime()
    local result = fire()
    if result ~= "ok" then
      ark_test.fail(label .. " returned unexpected result: " .. vim.inspect(result))
    end
    ark_test.wait_for(label .. " dispatch", 1000, function()
      return #samples[label] >= expected
    end)
  end
end

local parent_help = _G.__ark_nvim_help_rpc
if type(parent_help) ~= "function" then
  ark_test.fail("parent ArkHelp RPC function was not registered")
end
local parent_view = _G.__ark_nvim_view_rpc
if type(parent_view) ~= "function" then
  ark_test.fail("parent ArkView RPC function was not registered")
end

measure("parent_help", function()
  return parent_help("lm")
end)
measure("parent_view", function()
  return parent_view("mtcars")
end)

local console_buf, console_err = ark.console()
if not console_buf then
  ark_test.fail("failed to start nvim console: " .. tostring(console_err))
end

local console_help = _G.__ark_console_rpc_ark_help
if type(console_help) ~= "function" then
  ark_test.fail("Ark console help RPC function was not registered")
end
local console_view = _G.__ark_console_rpc_ark_view
if type(console_view) ~= "function" then
  ark_test.fail("Ark console View RPC function was not registered")
end

measure("console_help", function()
  return console_help("lm")
end)
measure("console_view", function()
  return console_view("mtcars")
end)

ark.help_topic = original_help_topic
ark.view = original_view

local max_ms = tonumber(vim.env.ARK_R_ENTRYPOINT_RPC_MAX_MS or "8") or 8
local medians = {
  parent_help = assert_budget("parent ArkHelp RPC", samples.parent_help, max_ms),
  parent_view = assert_budget("parent ArkView RPC", samples.parent_view, max_ms),
  console_help = assert_budget("console ArkHelp RPC", samples.console_help, max_ms),
  console_view = assert_budget("console ArkView RPC", samples.console_view, max_ms),
}

for label, values in pairs(samples) do
  for _, value in ipairs(values) do
    perf.record("rpc." .. label, value, {
      test = "r_entrypoint_rpc_latency.lua",
      condition = "warm in-process callback",
      fixture = "ArkHelp and ArkView parent/console entrypoints",
    })
  end
end

vim.print({
  r_entrypoint_rpc_latency = "ok",
  max_ms = max_ms,
  medians = medians,
  samples = samples,
})

stop_watchdog()
