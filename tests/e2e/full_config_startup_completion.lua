local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

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

-- This reproduces the user's real startup flow under ~/.config/nvim: open an
-- R buffer, wait for Ark's async startup, and require Ark's LSP to provide
-- script-side completions and diagnostics after hydration. In no-pane configs,
-- package metadata and static/script features must work without inventing a
-- live `.GlobalEnv`; deterministic objects attached in a virgin R session,
-- such as datasets::mtcars, should still provide object-member completions.
-- Real Blink popup recovery is covered by the TUI startup completion test.
local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function current_status()
  local ark = package.loaded["ark"]
  if type(ark) ~= "table" then
    return nil
  end

  return ark.status({ include_lsp = true })
end

local function lazy_plugin_loaded(name)
  local ok, lazy_config = pcall(require, "lazy.core.config")
  if not ok then
    return package.loaded[name] ~= nil
  end

  local plugin = lazy_config.plugins and lazy_config.plugins[name] or nil
  if type(plugin) ~= "table" then
    return package.loaded[name] ~= nil
  end

  return type(plugin._) == "table" and plugin._.loaded ~= nil
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

  local response = client:request_sync("textDocument/completion", params, 2000, 0)

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

local function request_completion_at_cursor(prefix)
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

  local response = ark_test.request(client, "textDocument/completion", params, 5000)
  return ark_test.completion_items(response)
end

local function reset_buffer(lines)
  stop_insert_mode()
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
  local lsp_ready = vim.wait(15000, function()
    local labels = completion_labels_at_cursor(prefix)
    if vim.tbl_contains(labels, expected_label) then
      lsp_ready_ms = elapsed_ms() - phase_begin_ms
      return true
    end
    return false
  end, 50, false)

  local lsp_labels = completion_labels_at_cursor(prefix)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  stop_insert_mode()

  return {
    prefix = prefix,
    expected_label = expected_label,
    typed_elapsed_ms = typed_elapsed_ms,
    lsp_ready = lsp_ready,
    lsp_ready_ms = lsp_ready_ms,
    lsp_labels = lsp_labels,
    found_in_lsp = vim.tbl_contains(lsp_labels, expected_label),
    cursor = cursor,
    line = line,
  }
end

local function wait_for_missing_package_diagnostic(package)
  reset_buffer({ "library(" .. package .. ")" })

  local message = nil
  local ok = vim.wait(15000, function()
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
      if type(diagnostic.message) == "string" and diagnostic.message:find(package, 1, true) then
        message = diagnostic.message
        return true
      end
    end
    return false
  end, 100, false)

  return {
    package = package,
    found = ok,
    message = message,
    diagnostics = vim.diagnostic.get(0),
  }
end

local function resolve_completion(item)
  local client = current_client()
  if not client then
    return nil
  end
  return ark_test.request(client, "completionItem/resolve", item, 10000)
end

ark_test.wait_for("R filetype", 10000, function()
  return vim.bo.filetype == "r"
end)
mark("filetype")

-- Full-config startup may intentionally run without a managed pane. Wait for
-- lazy.nvim to load Ark's plugin spec before touching `require("ark")`; a
-- direct module require can otherwise initialize Ark with default options and
-- mask the user's no-pane configuration.
ark_test.wait_for("ark lazy plugin load", 15000, function()
  return lazy_plugin_loaded("ark.nvim")
end)
mark("ark_loaded")

local ark = require("ark")
local ark_options = ark.options()
local expect_managed_pane = ark_options.auto_start_pane == true

if expect_managed_pane then
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
end

ark_test.wait_for("ark lsp client", 30000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)
mark("lsp_client")

ark_test.wait_for("ark lsp hydrated", 30000, function()
  local status = current_status()
  local lsp_status = status and status.lsp_status or nil
  if type(lsp_status) ~= "table" or lsp_status.available ~= true then
    return false
  end

  if expect_managed_pane then
    return tonumber(lsp_status.consoleScopeCount or 0) > 0
      and tonumber(lsp_status.libraryPathCount or 0) > 0
  end

  return lsp_status.runtimeMode == "detached"
    and tonumber(lsp_status.libraryPathCount or 0) > 0
    and tonumber(lsp_status.installedPackageCount or 0) > 0
end)
mark("lsp_hydrated")

ark_test.wait_for_main_buffer_unlocked(30000, 0)
mark("main_buffer_unlocked")

local startup = ark_test.startup_status(0) or {}
local startup_elapsed_ms = tonumber(startup.main_buffer_unlock_elapsed_ms) or ((vim.loop.hrtime() / 1e6) - startup_begin_ms)
if startup_elapsed_ms > 2000 then
  ark_test.fail(vim.inspect({
    error = string.format("async startup exceeded 2000 ms: %.1f ms", startup_elapsed_ms),
    marks = marks,
    status = current_status(),
  }))
end

local library_completion = type_and_capture_completion("libr", "library")
local namespace_completion = type_and_capture_completion("utils::he", "head")
local dollar_completion = type_and_capture_completion("mtcars$mp", "mpg")

reset_buffer({ "" })
vim.api.nvim_feedkeys("Autils::he", "xt", false)
ark_test.wait_for("typed namespace completion text", 4000, function()
  return vim.api.nvim_get_current_line() == "utils::he"
end)
local namespace_items = {}
local namespace_item = nil
local namespace_item_ready = vim.wait(5000, function()
  namespace_items = request_completion_at_cursor("utils::he")
  namespace_item = ark_test.find_item(namespace_items, "head")
  return namespace_item ~= nil
end, 100, false)
local resolved_namespace_item = namespace_item and resolve_completion(namespace_item) or nil
local resolved_doc = resolved_namespace_item and resolved_namespace_item.documentation or nil
local resolved_doc_text = nil
if type(resolved_doc) == "table" then
  resolved_doc_text = resolved_doc.value or (resolved_doc.MarkupContent and resolved_doc.MarkupContent.value)
end
if type(resolved_doc_text) ~= "string" then
  resolved_doc_text = vim.inspect(resolved_doc)
end

local missing_package = "arkdefinitelymissingpackage"
local missing_package_diagnostic = wait_for_missing_package_diagnostic(missing_package)

local completion_ok = library_completion.found_in_lsp and namespace_completion.found_in_lsp
completion_ok = completion_ok and dollar_completion ~= nil and dollar_completion.found_in_lsp
completion_ok = completion_ok and namespace_item_ready == true

local docs_ok = type(resolved_doc_text) == "string" and resolved_doc_text:find("head", 1, true) ~= nil
if not completion_ok or not docs_ok or not missing_package_diagnostic.found then
  ark_test.fail(vim.inspect({
    marks = marks,
    startup_elapsed_ms = startup_elapsed_ms,
    library_completion = library_completion,
    namespace_completion = namespace_completion,
    namespace_item_ready = namespace_item_ready,
    namespace_item = namespace_item,
    namespace_item_labels = ark_test.item_labels(namespace_items),
    resolved_namespace_item = resolved_namespace_item,
    resolved_doc_text = resolved_doc_text,
    missing_package_diagnostic = missing_package_diagnostic,
    mtcars_dollar_completion = dollar_completion,
    ark_options = {
      auto_start_pane = ark_options.auto_start_pane,
      auto_start_lsp = ark_options.auto_start_lsp,
      async_startup = ark_options.async_startup,
    },
    status = current_status(),
  }))
end

vim.print({
  marks = marks,
  library_completion = library_completion,
  namespace_completion = namespace_completion,
  resolved_doc_text = resolved_doc_text,
  missing_package_diagnostic = missing_package_diagnostic,
  mtcars_dollar_completion = dollar_completion,
  startup_elapsed_ms = startup_elapsed_ms,
  ark_options = {
    auto_start_pane = ark_options.auto_start_pane,
    auto_start_lsp = ark_options.auto_start_lsp,
    async_startup = ark_options.async_startup,
  },
  status = current_status(),
})
