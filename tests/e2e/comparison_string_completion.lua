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
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_comparison_string_completion.R"

vim.fn.writefile({
  'colors_ark == "a',
  'levels_ark != "b',
  'dt_cmp_ark[color == "a',
  'mtcars$cyl == "4',
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
  'colors_ark <- c("apple", "banana", "apricot"); levels_ark <- factor(c("beta", "banana", "berry")); ark_dt_available <- requireNamespace("data.table", quietly = TRUE); if (ark_dt_available) dt_cmp_ark <- data.table::data.table(color = c("apple", "banana", "apricot"))',
  "Enter",
  "ark_dt_available",
  "Enter",
})

wait_for("comparison fixture setup", 10000, function()
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("ark_dt_available", 1, true) ~= nil
    and (capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil)
end)

local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
local has_data_table = capture:find("%[1%] TRUE") ~= nil

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  return completion_items(request(client, "textDocument/completion", params))
end

local colors_items = completion_at(1, #lines[1])
local apple = find_item(colors_items, "apple")
if not apple then
  fail('colors_ark == " completion missing apple: ' .. vim.inspect(item_labels(colors_items)))
end
if insert_text(apple) ~= "apple" then
  fail('colors_ark == " completion inserted unexpected text: ' .. vim.inspect(apple))
end

local levels_items = completion_at(2, #lines[2])
local banana = find_item(levels_items, "banana")
if not banana then
  fail('levels_ark != " completion missing banana: ' .. vim.inspect(item_labels(levels_items)))
end
if insert_text(banana) ~= "banana" then
  fail('levels_ark != " completion inserted unexpected text: ' .. vim.inspect(banana))
end

local result = {
  colors = insert_text(apple),
  levels = insert_text(banana),
}

if has_data_table then
  local dt_items = completion_at(3, #lines[3])
  local apricot = find_item(dt_items, "apple")
  if not apricot then
    fail('dt_cmp_ark[color == " completion missing apple: ' .. vim.inspect(item_labels(dt_items)))
  end
  if insert_text(apricot) ~= "apple" then
    fail('dt_cmp_ark[color == " completion inserted unexpected text: ' .. vim.inspect(apricot))
  end
  result.data_table = insert_text(apricot)
else
  result.data_table = "skipped"
end

local numeric_items = completion_at(4, #lines[4])
if #numeric_items ~= 0 then
  fail('mtcars$cyl == " completion expected no string completions: ' .. vim.inspect(item_labels(numeric_items)))
end
result.numeric = "ok"

vim.print(result)
