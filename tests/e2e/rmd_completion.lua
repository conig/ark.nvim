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
  if response.error or response.err then
    fail(method .. " error: " .. vim.inspect(response.error or response.err))
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

local test_file = "/tmp/ark_rmd_completion.Rmd"

vim.fn.writefile({
  "---",
  'title: "Ark R Markdown completion"',
  "---",
  "",
  "```{r}",
  "whi",
  "```",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype rmd")

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

-- Simulate normal typing inside an R chunk after open. This exercises the
-- incremental didChange path rather than only the initial parse.
vim.api.nvim_buf_set_text(0, 5, 2, 5, 2, { "i" })
vim.wait(500, function()
  return false
end, 500, false)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local result = request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 5, character = 3 },
}, 10000)

local items = completion_items(result)
local while_keyword = find_item(items, "while")
if not while_keyword then
  fail("keyword completion missing while inside rmd chunk: " .. vim.inspect(items))
end

vim.print({
  label = while_keyword.label,
  total = #items,
})
