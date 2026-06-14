vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(45000, "nvim_console_namespaced_argument_completion")

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_namespaced_argument_completion")
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

local function completion_at_input(text, context)
  local status = require("ark.console").status(bufnr)
  local input_start = status.input_start
  vim.api.nvim_buf_set_lines(bufnr, input_start, -1, false, { text })
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_cursor(0, { input_start + 1, #text })
  vim.wait(250, function()
    return false
  end, 250, false)

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = {
      line = input_start,
      character = #text,
    },
    context = context,
  }, 10000))
end

local items = completion_at_input("corx::corx(", {
  triggerKind = 2,
  triggerCharacter = "(",
})
local random_seed = ark_test.find_item(items, ".Random.seed")
if random_seed then
  ark_test.fail("corx::corx( console completion unexpectedly included .Random.seed: " .. vim.inspect(ark_test.item_labels(items)))
end

for _, label in ipairs({ "data", "x", "method" }) do
  local item = ark_test.find_item(items, label)
  if not item then
    ark_test.fail("corx::corx( console completion missing " .. label .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end
  if ark_test.insert_text(item) ~= label .. " = " then
    ark_test.fail("corx::corx( console completion inserted unexpected text for " .. label .. ": " .. vim.inspect(item))
  end
end

-- Regression for completing an object name in a named argument value. This is
-- the user-visible console shape `corx::corx(data = mtca`, which should offer
-- `mtcars` from the live R search path rather than staying in argument-name
-- completion.
local value_items = completion_at_input("corx::corx(data = mtca", {
  triggerKind = 1,
})
local mtcars = ark_test.find_item(value_items, "mtcars")
if not mtcars then
  ark_test.fail("corx::corx(data = mtca console completion missing mtcars: " .. vim.inspect(ark_test.item_labels(value_items)))
end
if ark_test.insert_text(mtcars) ~= "mtcars" then
  ark_test.fail("corx::corx(data = mtca console completion inserted unexpected text: " .. vim.inspect(mtcars))
end

vim.print({
  nvim_console_namespaced_argument_completion = "ok",
})

stop_watchdog()
