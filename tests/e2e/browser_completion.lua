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
  local command = { "tmux" }
  local explicit_socket = vim.env.ARK_TMUX_SOCKET
  if type(explicit_socket) == "string" and explicit_socket ~= "" then
    command[#command + 1] = "-S"
    command[#command + 1] = explicit_socket
  else
    local tmux_env = vim.env.TMUX
    if type(tmux_env) == "string" and tmux_env ~= "" then
      local socket = vim.split(tmux_env, ",", { plain = true })[1]
      if type(socket) == "string" and socket ~= "" then
        command[#command + 1] = "-S"
        command[#command + 1] = socket
      end
    end
  end

  local output = vim.fn.system(vim.list_extend(command, args))
  if vim.v.shell_error ~= 0 then
    fail("tmux command failed: " .. output)
  end
  return output
end

local function request(client, method, params, timeout_ms)
  local response, err = client:request_sync(method, params, timeout_ms or 10000, 0)
  if err then
    fail(method .. " error: " .. err)
  end
  if not response then
    fail("no response for " .. method)
  end
  if response.error then
    fail(method .. " error: " .. vim.inspect(response.error))
  end
  if response.err then
    fail(method .. " error: " .. vim.inspect(response.err))
  end
  return response.result
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
  return client ~= nil and client.initialized == true and not client:is_stopped()
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
local params = {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = 18 },
}
local completion = request(client, "textDocument/completion", params)
local labels = item_labels(completion_items(completion))

tmux({ "send-keys", "-t", pane_id, "c", "Enter" })

if not contains(labels, browser_symbol) then
  fail("browser() completion missing local symbol: " .. vim.inspect(labels))
end

vim.print({
  browser_symbol = browser_symbol,
  completions = labels,
})
