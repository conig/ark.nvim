local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
end

local function tmux(args)
  local output = vim.fn.system(vim.list_extend({ "tmux" }, args))
  if vim.v.shell_error ~= 0 then
    fail("tmux command failed: " .. output)
  end
  return output
end

local function request(method, params, timeout_ms)
  local responses = vim.lsp.buf_request_sync(0, method, params, timeout_ms or 10000)
  if not responses or next(responses) == nil then
    fail("no response for " .. method)
  end

  for _, response in pairs(responses) do
    if response.error then
      fail(method .. " error: " .. vim.inspect(response.error))
    end
    return response.result
  end

  fail("empty response table for " .. method)
end

local function completion_items(result)
  if type(result) ~= "table" then
    return {}
  end
  if vim.islist(result) then
    return result
  end
  return result.items or {}
end

local function item_labels(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.label
  end
  return out
end

local function contains(tbl, needle)
  for _, value in ipairs(tbl) do
    if value == needle then
      return true
    end
  end
  return false
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_browser_completion.R"
local browser_symbol = "alpha_local_browser_ark"

vim.fn.writefile({
  "alpha_local_browse",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true
end)

local pane_id = require("ark").status().pane_id
if type(pane_id) ~= "string" or pane_id == "" then
  fail("managed pane id missing")
end

tmux({
  "send-keys",
  "-t",
  pane_id,
  "f <- function() { alpha_local_browser_ark <- 1; browser(); NULL }",
  "Enter",
  "f()",
  "Enter",
})

wait_for("browser() prompt", 10000, function()
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("Browse%[", 1) ~= nil
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
local completion = request("textDocument/completion", params)
local labels = item_labels(completion_items(completion))

tmux({ "send-keys", "-t", pane_id, "c", "Enter" })

if not contains(labels, browser_symbol) then
  fail("browser() completion missing local symbol: " .. vim.inspect(labels))
end

vim.print({
  browser_symbol = browser_symbol,
  completions = labels,
})
