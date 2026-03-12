local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
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

local function find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_completion_resolve.R"

vim.fn.writefile({
  "mtcars$m",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")
vim.api.nvim_win_set_cursor(0, { 1, 8 })

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
local completion = request("textDocument/completion", params)
local item = find_item(completion_items(completion), "mpg")

if not item then
  fail("mtcars$ completion did not include mpg")
end

if item.detail == "unknown" then
  fail("completion item still exposes unknown detail before resolve")
end

local resolved = request("completionItem/resolve", item)
local detail = resolved and resolved.detail or ""
local documentation = resolved and resolved.documentation
local documentation_value = documentation and documentation.value or ""

if detail == "" or detail == "unknown" then
  fail("resolved completion detail missing: " .. vim.inspect(resolved))
end

if type(documentation_value) ~= "string" or documentation_value == "" then
  fail("resolved completion docs missing: " .. vim.inspect(resolved))
end

vim.print({
  detail = detail,
  documentation = documentation_value,
})
