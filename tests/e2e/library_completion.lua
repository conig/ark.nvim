local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
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
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local params = {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = 11 },
}
local completion = request(client, "textDocument/completion", params)
local labels = item_labels(completion_items(completion))

if not contains(labels, "utils") then
  fail("library() completion missing utils: " .. vim.inspect(labels))
end

vim.print({
  completions = labels,
})
