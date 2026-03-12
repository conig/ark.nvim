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

local test_file = "/tmp/ark_library_completion.R"

vim.fn.writefile({
  "library(uti",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")
vim.api.nvim_win_set_cursor(0, { 1, 11 })

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
local labels = item_labels(completion_items(completion))

if not contains(labels, "utils") then
  fail("library() completion missing utils: " .. vim.inspect(labels))
end

vim.print({
  completions = labels,
})
