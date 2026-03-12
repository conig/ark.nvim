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

local function insert_text(item)
  return item.insertText or item.insert_text
end

local function completion_at(line, column)
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  local result = request(client, "textDocument/completion", params, 10000)
  return completion_items(result)
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_detached_parity.R"

vim.fn.writefile({
  "whi",
  "mtcars |> subset(m",
  'library("uti',
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
vim.wait(300, function()
  return false
end, 300, false)

local keyword_items = completion_at(1, 3)
local while_keyword = find_item(keyword_items, "while")
if not while_keyword then
  fail("keyword completion missing while: " .. vim.inspect(keyword_items))
end

local pipe_items = completion_at(2, 18)
local pipe_column = find_item(pipe_items, "mpg")
if not pipe_column then
  fail("pipe completion missing mpg: " .. vim.inspect(pipe_items))
end
if insert_text(pipe_column) ~= "mpg" then
  fail("pipe completion inserted unexpected text: " .. vim.inspect(pipe_column))
end

local library_items = completion_at(3, 12)
local utils_pkg = find_item(library_items, "utils")
if not utils_pkg then
  fail('quoted library() completion missing utils: ' .. vim.inspect(library_items))
end

vim.print({
  keyword = while_keyword.label,
  pipe = insert_text(pipe_column),
  library = utils_pkg.label,
})
