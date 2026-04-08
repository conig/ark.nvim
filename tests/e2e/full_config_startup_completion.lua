local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  ark_test.fail("blink.cmp is required for this test")
end

local list = require("blink.cmp.completion.list")
local startup_begin_ms = vim.loop.hrtime() / 1e6
local marks = {}

local function elapsed_ms()
  return (vim.loop.hrtime() / 1e6) - startup_begin_ms
end

local function mark(name)
  if marks[name] == nil then
    marks[name] = elapsed_ms()
  end
end

-- This reproduces the user's real startup flow under ~/.config/nvim:
-- open an R buffer, wait for Ark's async startup, type `libr`, then type
-- `mtcars$`, and require the visible completion menu to contain the expected
-- items rather than relying on a direct LSP request.
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

local function item_index(label)
  for index, item in ipairs(list.items) do
    if item.label == label then
      return index
    end
  end
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

local function stop_insert_mode()
  if vim.fn.mode() == "i" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    ark_test.wait_for("normal mode", 4000, function()
      return vim.fn.mode() == "n"
    end)
  end
end

local function reset_buffer(lines)
  stop_insert_mode()
  blink.hide()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function type_and_capture_completion(prefix, expected_label)
  reset_buffer({ "" })
  local phase_begin_ms = elapsed_ms()
  vim.api.nvim_feedkeys("A" .. prefix, "xt", false)
  ark_test.wait_for("typed text " .. prefix, 4000, function()
    return vim.api.nvim_get_current_line() == prefix
  end)
  local typed_elapsed_ms = elapsed_ms() - phase_begin_ms

  local lsp_ready_ms = nil
  local lsp_ready = vim.wait(10000, function()
    local labels = completion_labels_at_cursor(prefix)
    if vim.tbl_contains(labels, expected_label) then
      lsp_ready_ms = elapsed_ms() - phase_begin_ms
      return true
    end
    return false
  end, 50, false)

  local menu_ready = vim.wait(10000, function()
    return blink.is_visible() and item_index(expected_label) ~= nil
  end, 100, false)
  local blink_ready_ms = menu_ready and (elapsed_ms() - phase_begin_ms) or nil
  local index = item_index(expected_label)
  local blink_visible = blink.is_visible()
  local blink_labels = vim.tbl_map(function(item)
    return item.label
  end, list.items)
  if blink_visible and index ~= nil then
    ark_test.assert_no_snippet_items(list.items, expected_label)
  end
  local lsp_labels = completion_labels_at_cursor(prefix)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  blink.hide()
  stop_insert_mode()

  return {
    prefix = prefix,
    expected_label = expected_label,
    typed_elapsed_ms = typed_elapsed_ms,
    lsp_ready = lsp_ready,
    lsp_ready_ms = lsp_ready_ms,
    menu_ready = menu_ready,
    blink_ready_ms = blink_ready_ms,
    blink_visible = blink_visible,
    blink_labels = blink_labels,
    lsp_labels = lsp_labels,
    found_in_blink = index ~= nil,
    found_in_lsp = vim.tbl_contains(lsp_labels, expected_label),
    cursor = cursor,
    line = line,
  }
end

ark_test.wait_for("R filetype", 10000, function()
  return vim.bo.filetype == "r"
end)
mark("filetype")

ark_test.wait_for("ark plugin load", 15000, function()
  return package.loaded["ark"] ~= nil
end)
mark("ark_loaded")

ark_test.wait_for("ark bridge ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.bridge_ready == true
end)
mark("bridge_ready")

ark_test.wait_for("managed R repl ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.repl_ready == true
end)
mark("repl_ready")

ark_test.wait_for("ark lsp client", 30000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)
mark("lsp_client")

ark_test.wait_for("ark lsp hydrated", 30000, function()
  local status = current_status()
  local lsp_status = status and status.lsp_status or nil
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)
mark("lsp_hydrated")

local startup_elapsed_ms = (vim.loop.hrtime() / 1e6) - startup_begin_ms
if startup_elapsed_ms > 2000 then
  ark_test.fail(vim.inspect({
    error = string.format("async startup exceeded 2000 ms: %.1f ms", startup_elapsed_ms),
    marks = marks,
    status = current_status(),
  }))
end

local library_completion = type_and_capture_completion("libr", "library")
local dollar_completion = type_and_capture_completion("mtcars$", "mpg")

if not library_completion.found_in_lsp or not dollar_completion.found_in_lsp then
  ark_test.fail(vim.inspect({
    marks = marks,
    startup_elapsed_ms = startup_elapsed_ms,
    library_completion = library_completion,
    mtcars_dollar_completion = dollar_completion,
    status = current_status(),
  }))
end

vim.print({
  marks = marks,
  library_completion = library_completion,
  mtcars_dollar_completion = dollar_completion,
  startup_elapsed_ms = startup_elapsed_ms,
  status = current_status(),
})
