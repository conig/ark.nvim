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
  local response, err = client.request_sync(client, method, params, timeout_ms or 10000, 0)
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
end

local function completion_at(client, line, column, trigger_character)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  if trigger_character then
    params.context = {
      triggerKind = 2,
      triggerCharacter = trigger_character,
    }
  end
  return completion_items(request(client, "textDocument/completion", params, 10000))
end

local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype == "" then
  vim.cmd("setfiletype r")
end

wait_for("Ark commands", 10000, function()
  return vim.fn.exists(":ArkPaneStart") == 2 and vim.fn.exists(":ArkLspStart") == 2
end)

local ok, ark = pcall(require, "ark")
if not ok then
  fail("failed to load ark.nvim from README test config")
end

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  fail("failed to load blink.cmp from README test config")
end

local ok_autopairs = pcall(require, "nvim-autopairs")
if not ok_autopairs then
  fail("failed to load nvim-autopairs from README test config")
end

local ok_blink_config, blink_config = pcall(require, "blink.cmp.config")
if not ok_blink_config then
  fail("failed to load blink.cmp.config from README test config")
end

local ok_slimetree = pcall(require, "nvim-slimetree")
if not ok_slimetree then
  fail("failed to load nvim-slimetree from README test config")
end

local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype) or vim.bo[bufnr].filetype
local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
if not ok_parser or parser == nil then
  fail("README test config is missing the Tree-sitter parser needed for nvim-slimetree sends on this buffer")
end

local r_sources = blink_config.sources
  and blink_config.sources.per_filetype
  and blink_config.sources.per_filetype.r
if type(r_sources) ~= "table" or not vim.tbl_contains(r_sources, "ark_lsp") then
  fail("blink.cmp was not patched with Ark sources for R buffers")
end

if type(blink.is_visible) ~= "function" then
  fail("blink.cmp did not finish setup")
end

local st = require("nvim-slimetree")

wait_for("managed pane", 30000, function()
  local status = ark.status({ include_lsp = true })
  return type(status) == "table" and status.managed == true and status.pane_exists == true
end)

wait_for("bridge ready", 30000, function()
  local status = ark.status({ include_lsp = true })
  return type(status) == "table" and status.bridge_ready == true
end)

wait_for("repl ready", 30000, function()
  local status = ark.status({ include_lsp = true })
  return type(status) == "table" and status.repl_ready == true
end)

wait_for("lsp ready", 30000, function()
  local status = ark.status({ include_lsp = true })
  return type(status) == "table"
    and type(status.lsp_status) == "table"
    and status.lsp_status.available == true
end)

wait_for("lsp hydration", 30000, function()
  local status = ark.status({ include_lsp = true })
  local lsp_status = type(status) == "table" and status.lsp_status or nil
  return type(lsp_status) == "table"
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

local status = ark.status({ include_lsp = true })
local session = status and status.session or nil
if type(session) ~= "table" then
  fail("missing tmux session metadata for README test config")
end

local socket = session.tmux_socket
local pane = session.tmux_pane
if type(socket) ~= "string" or socket == "" or type(pane) ~= "string" or pane == "" then
  fail("missing tmux pane target for README test config")
end

local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
if not client or client.initialized ~= true or (client.is_stopped and client:is_stopped()) then
  fail("missing live ark_lsp client for README test config")
end

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  'library("uti',
  "mtcars$",
})

local library_items = nil
wait_for("library completion", 10000, function()
  library_items = completion_at(client, 1, 12)
  return find_item(library_items, "utils") ~= nil
end)
if not find_item(library_items, "utils") then
  fail('README test config library() completion missing "utils": ' .. vim.inspect(library_items))
end

local mtcars_items = nil
wait_for("mtcars$ completion", 10000, function()
  mtcars_items = completion_at(client, 2, 7, "$")
  return find_item(mtcars_items, "mpg") ~= nil
end)
if not find_item(mtcars_items, "mpg") then
  fail('README test config mtcars$ completion missing "mpg": ' .. vim.inspect(mtcars_items))
end

local token = "ARK_README_SEND_SMOKE"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  string.format('cat("%s\\n")', token),
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local send_result = st.slimetree.send_line()
if type(send_result) ~= "table" or send_result.ok ~= true then
  fail("nvim-slimetree send_line() failed in README test config: " .. vim.inspect(send_result))
end

wait_for("line send to managed pane", 10000, function()
  local capture = vim.fn.system({
    "tmux",
    "-S",
    socket,
    "capture-pane",
    "-p",
    "-t",
    pane,
  })
  return vim.v.shell_error == 0 and type(capture) == "string" and capture:find(token, 1, true) ~= nil
end)

vim.print({
  status = ark.status({ include_lsp = true }),
  library_completion = "utils",
  mtcars_completion = "mpg",
  send_line = token,
})
vim.cmd("qa!")
