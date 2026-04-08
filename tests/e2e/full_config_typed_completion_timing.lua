local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  error("blink.cmp is required for this probe")
end

local list = require("blink.cmp.completion.list")
local start_ms = vim.loop.hrtime() / 1e6
local marks = {}

local function elapsed_ms()
  return (vim.loop.hrtime() / 1e6) - start_ms
end

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function current_status()
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end
  return ark.status({ include_lsp = true })
end

local function mark(name)
  if marks[name] == nil then
    marks[name] = elapsed_ms()
  end
end

local function await_mark(name, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 50, false)
  if ok then
    mark(name)
  end
  return ok
end

local function completion_labels_at_cursor(prefix)
  local client = current_client()
  if not client then
    return {}
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local character = vim.fn.strchars(prefix)

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = {
      line = cursor[1] - 1,
      character = character,
    },
  }

  local trigger_character = prefix:sub(-1)
  if trigger_character == "$" or trigger_character == "@" or trigger_character == ":" or trigger_character == '"' then
    params.context = {
      triggerKind = 2,
      triggerCharacter = trigger_character,
    }
  end

  local response = client:request_sync("textDocument/completion", params, 10000, 0)
  if not response or response.error or response.err then
    return {}
  end

  return ark_test.item_labels(ark_test.completion_items(response.result))
end

local function item_index(label)
  for index, item in ipairs(list.items) do
    if item.label == label then
      return index
    end
  end
end

local function stop_insert_mode()
  if vim.fn.mode() == "i" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    vim.wait(2000, function()
      return vim.fn.mode() == "n"
    end, 20, false)
  end
end

local function reset_buffer(lines)
  stop_insert_mode()
  blink.hide()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function probe_completion(prefix, expected_label)
  reset_buffer({ "" })
  local phase_start = elapsed_ms()
  vim.api.nvim_feedkeys("A" .. prefix, "xt", false)
  local typed_ok = vim.wait(4000, function()
    return vim.api.nvim_get_current_line() == prefix
  end, 20, false)

  local lsp_ready_ms = nil
  local lsp_ok = vim.wait(15000, function()
    local labels = completion_labels_at_cursor(prefix)
    if vim.tbl_contains(labels, expected_label) then
      lsp_ready_ms = elapsed_ms() - phase_start
      return true
    end
    return false
  end, 50, false)

  local blink_ready_ms = nil
  local blink_ok = vim.wait(15000, function()
    if blink.is_visible() and item_index(expected_label) ~= nil then
      blink_ready_ms = elapsed_ms() - phase_start
      return true
    end
    return false
  end, 50, false)

  local lsp_labels = completion_labels_at_cursor(prefix)
  local blink_labels = vim.tbl_map(function(item)
    return item.label
  end, list.items)
  if blink.is_visible() and item_index(expected_label) ~= nil then
    ark_test.assert_no_snippet_items(list.items, expected_label)
  end
  local result = {
    prefix = prefix,
    expected_label = expected_label,
    typed_ok = typed_ok,
    typed_elapsed_ms = elapsed_ms() - phase_start,
    lsp_ok = lsp_ok,
    lsp_ready_ms = lsp_ready_ms,
    blink_ok = blink_ok,
    blink_ready_ms = blink_ready_ms,
    blink_visible = blink.is_visible(),
    found_in_lsp = vim.tbl_contains(lsp_labels, expected_label),
    found_in_blink = item_index(expected_label) ~= nil,
    lsp_labels = lsp_labels,
    blink_labels = blink_labels,
    cursor = vim.api.nvim_win_get_cursor(0),
    line = vim.api.nvim_get_current_line(),
  }
  blink.hide()
  stop_insert_mode()
  return result
end

await_mark("filetype", 10000, function()
  return vim.bo.filetype == "r"
end)

await_mark("ark_loaded", 15000, function()
  return package.loaded["ark"] ~= nil
end)

await_mark("bridge_ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.bridge_ready == true
end)

await_mark("repl_ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.repl_ready == true
end)

await_mark("lsp_client", 30000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local hydrated = await_mark("lsp_hydrated", 30000, function()
  local status = current_status()
  local lsp_status = status and status.lsp_status or nil
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

local library_completion = probe_completion("libr", "library")
local dollar_completion = probe_completion("mtcars$", "mpg")

vim.print({
  marks = marks,
  hydrated = hydrated,
  startup_elapsed_ms = elapsed_ms(),
  library_completion = library_completion,
  mtcars_dollar_completion = dollar_completion,
  status = current_status(),
})
