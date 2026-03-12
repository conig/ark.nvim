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
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local params = {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = 8 },
}
local completion = request(client, "textDocument/completion", params)
local item = find_item(completion_items(completion), "mpg")

if not item then
  fail("mtcars$ completion did not include mpg")
end

if item.detail == "unknown" then
  fail("completion item still exposes unknown detail before resolve")
end

local resolved = request(client, "completionItem/resolve", item)
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
