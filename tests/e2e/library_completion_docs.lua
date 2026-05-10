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

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_library_completion_docs.R"

vim.fn.writefile({
  "library(gg",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")
vim.api.nvim_win_set_cursor(0, { 1, 10 })

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
  position = { line = 0, character = 10 },
}
local completion = request(client, "textDocument/completion", params)
local item = find_item(completion_items(completion), "ggplot2")

if not item then
  fail("library() completion missing ggplot2")
end

-- Regression coverage for Blink's floating completion docs: package
-- completions must resolve to DESCRIPTION/help text, not the bridge's
-- placeholder NULL metadata for the completion sentinel object.
local resolved = request(client, "completionItem/resolve", item)
local detail = resolved and resolved.detail or ""
local doc = documentation_value(resolved)
local doc_lower = doc:lower()

if detail == "NULL" or doc == "NULL" or doc_lower:find("null", 1, true) then
  fail("library() package docs resolved to NULL metadata: " .. vim.inspect(resolved))
end

if doc == "" then
  fail("library() package docs missing after resolve: " .. vim.inspect(resolved))
end

if not (doc_lower:find("ggplot2", 1, true) or doc_lower:find("grammar", 1, true)) then
  fail("library() package docs do not describe ggplot2: " .. vim.inspect(resolved))
end

vim.print({
  detail = detail,
  documentation = doc,
})
