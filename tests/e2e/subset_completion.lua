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

local function item_labels(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.label
  end
  return out
end

local function insert_text(item)
  return item.insertText or item.insert_text
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_subset_completion.R"

vim.fn.writefile({
  "mtcars[",
  'mtcars[, c("',
  'mtcars[["',
  "dt_ark[",
  "dt_ark[as.char",
  "dt_ark[, .(m",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

require("ark").start_pane()

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

require("ark").start_lsp(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

wait_for("managed R prompt", 10000, function()
  local capture = tmux({ "capture-pane", "-p", "-t", require("ark").status().pane_id })
  return capture:find("\n>", 1, true) ~= nil or capture:find("^>", 1) ~= nil
end)

local pane_id = require("ark").status().pane_id
if type(pane_id) ~= "string" or pane_id == "" then
  fail("managed pane id missing")
end

tmux({
  "send-keys",
  "-t",
  pane_id,
  'ark_dt_available <- requireNamespace("data.table", quietly = TRUE); if (ark_dt_available) dt_ark <- data.table::as.data.table(mtcars)',
  "Enter",
  "ark_dt_available",
  "Enter",
})

wait_for("data.table availability probe", 10000, function()
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil
end)

local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
local has_data_table = capture:find("%[1%] TRUE") ~= nil

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local encoding = client.offset_encoding

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  return completion_items(request(client, "textDocument/completion", params))
end

local df_subset_items = completion_at(1, 7)
local df_subset = find_item(df_subset_items, "mpg")
if not df_subset then
  fail("mtcars[ completion missing mpg: " .. vim.inspect(item_labels(df_subset_items)))
end
if insert_text(df_subset) ~= '"mpg"' then
  fail("mtcars[ completion inserted unexpected text: " .. vim.inspect(df_subset))
end

local df_string_subset_items = completion_at(2, 12)
local df_string_subset = find_item(df_string_subset_items, "mpg")
if not df_string_subset then
  fail('mtcars[, c(" completion missing mpg: ' .. vim.inspect(item_labels(df_string_subset_items)))
end
if insert_text(df_string_subset) ~= "mpg" then
  fail('mtcars[, c(" completion inserted unexpected text: ' .. vim.inspect(df_string_subset))
end

local df_subset2_items = completion_at(3, 9)
local df_subset2 = find_item(df_subset2_items, "mpg")
if not df_subset2 then
  fail('mtcars[[" completion missing mpg: ' .. vim.inspect(item_labels(df_subset2_items)))
end
if insert_text(df_subset2) ~= "mpg" then
  fail('mtcars[[" completion inserted unexpected text: ' .. vim.inspect(df_subset2))
end

local result = {
  mtcars_subset = insert_text(df_subset),
  mtcars_string_subset = insert_text(df_string_subset),
  mtcars_subset2 = insert_text(df_subset2),
}

if has_data_table then
  local dt_subset_items = completion_at(4, 7)
  local dt_subset = find_item(dt_subset_items, "mpg")
  if not dt_subset then
    fail("dt_ark[ completion missing mpg: " .. vim.inspect(item_labels(dt_subset_items)))
  end
  if insert_text(dt_subset) ~= "mpg" then
    fail("dt_ark[ completion inserted unexpected text: " .. vim.inspect(dt_subset))
  end
  result.dt_subset = insert_text(dt_subset)

  local dt_symbol_items = completion_at(5, 14)
  local dt_symbol = find_item(dt_symbol_items, "as.character")
  if not dt_symbol then
    fail("dt_ark[as.char completion missing as.character: " .. vim.inspect(item_labels(dt_symbol_items)))
  end
  result.dt_symbol = insert_text(dt_symbol)

  local dt_j_items = completion_at(6, 12)
  local dt_j = find_item(dt_j_items, "mpg")
  if not dt_j then
    fail("dt_ark[, .(m completion missing mpg: " .. vim.inspect(item_labels(dt_j_items)))
  end
  if insert_text(dt_j) ~= "mpg" then
    fail("dt_ark[, .(m completion inserted unexpected text: " .. vim.inspect(dt_j))
  end
  result.dt_j = insert_text(dt_j)
else
  result.dt_subset = "skipped"
  result.dt_symbol = "skipped"
  result.dt_j = "skipped"
end

vim.print(result)
