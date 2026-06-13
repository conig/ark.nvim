vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(45000, "nvim_console_argument_completion_docs")

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_argument_completion_docs")
end

local function documentation_value(item)
  local documentation = item and item.documentation
  if type(documentation) == "string" then
    return documentation
  end
  if type(documentation) == "table" then
    return documentation.value or ""
  end
  return ""
end

local function assert_documented_argument_item(client, item, label)
  if not item then
    ark_test.fail("missing argument completion item: " .. label)
  end
  if ark_test.insert_text(item) ~= label .. " = " then
    ark_test.fail("unexpected insert text for " .. label .. ": " .. vim.inspect(item))
  end

  local resolved = item
  if documentation_value(resolved) == "" then
    resolved = ark_test.request(client, "completionItem/resolve", item, 10000)
  end

  local doc = documentation_value(resolved)
  if doc == "" then
    ark_test.fail("missing argument completion docs for " .. label .. ": " .. vim.inspect(resolved))
  end
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(vim.fn.getcwd() .. "/scripts/ark-r-launcher.sh")
if vim.fn.executable(launcher) ~= 1 then
  ark_test.fail("Ark R launcher is not executable: " .. launcher)
end

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = true,
  async_startup = false,
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(vim.fn.getcwd() .. "/packages/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start real R nvim console: " .. tostring(err))
end

ark_test.wait_for("real R top-level prompt", 20000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

ark_test.wait_for("console bridge and REPL ready", 20000, function()
  local status = require("ark.console").status(bufnr)
  local bridge_status = type(status) == "table"
      and type(status.status_path) == "string"
      and require("ark.session_runtime").read_status_file(status.status_path, { require_live_pid = true })
    or nil
  return type(bridge_status) == "table"
    and bridge_status.status == "ready"
    and bridge_status.port ~= nil
    and bridge_status.repl_ready == true
end)

ark_test.wait_for("console ark_lsp client", 20000, function()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
local lsp_status = nil
ark_test.wait_for("console LSP session hydration", 20000, function()
  local response = client:request_sync("ark/internal/status", {}, 1000, bufnr)
  lsp_status = response and response.result or lsp_status
  local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
  return type(lsp_status) == "table"
    and lsp_status.sessionBridgeConfigured == true
    and type(detached_status) == "table"
    and type(detached_status.lastBootstrapSuccessMs) == "number"
end)

local ready_status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(
  bufnr,
  ready_status.input_start,
  -1,
  false,
  { [[cat("ark-console-argument-docs-ready\n"); flush.console()]] }
)
local ok, submit_err = require("ark.console").submit(bufnr)
if not ok then
  ark_test.fail("failed to submit real R console input: " .. tostring(submit_err))
end

ark_test.wait_for("console transcript output", 15000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> ark%-console%-argument%-docs%-ready") ~= nil
end)

local status = require("ark.console").status(bufnr)
local input_start = status.input_start
vim.api.nvim_buf_set_lines(bufnr, input_start, -1, false, { "lm(data = mtcars, " })
vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_win_set_cursor(0, { input_start + 1, #"lm(data = mtcars, " })
vim.wait(250, function()
  return false
end, 250, false)

local line = vim.api.nvim_buf_get_lines(bufnr, input_start, input_start + 1, false)[1]
local result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = {
    line = input_start,
    character = #line,
  },
  context = {
    triggerKind = 1,
  },
}, 10000)

local items = ark_test.completion_items(result)
local formula = ark_test.find_item(items, "formula")
if not formula then
  ark_test.fail("lm(data = mtcars, console completion missing formula: " .. vim.inspect(ark_test.item_labels(items)))
end
local subset = ark_test.find_item(items, "subset")
if not subset then
  ark_test.fail("lm(data = mtcars, console completion missing subset: " .. vim.inspect(ark_test.item_labels(items)))
end

assert_documented_argument_item(client, formula, "formula")
assert_documented_argument_item(client, subset, "subset")

vim.print({
  nvim_console_argument_completion_docs = "ok",
})

stop_watchdog()
