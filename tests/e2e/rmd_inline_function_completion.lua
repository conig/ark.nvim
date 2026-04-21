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

local test_file = "/tmp/ark_rmd_inline_function_completion.Rmd"

vim.fn.writefile({
  "---",
  'title: "Ark inline R function completion"',
  "---",
  "",
  "The row count is `r n`.",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype rmd")

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local line = vim.api.nvim_buf_get_lines(0, 4, 5, false)[1]
local completion_column = assert(line:find("`r n", 1, true)) + 3

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local result = request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 4, character = completion_column },
}, 10000)

local items = completion_items(result)
local nrow = find_item(items, "nrow")
if not nrow then
  fail("function completion missing nrow inside rmd inline expression: " .. vim.inspect(items))
end

vim.print({
  label = nrow.label,
  total = #items,
})
