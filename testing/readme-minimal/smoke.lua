local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
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

vim.print(ark.status({ include_lsp = true }))
vim.cmd("qa!")
