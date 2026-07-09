vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_view_object_tree")

local notifications = {}
local inputs = {}
local selections = {}
local close_calls = {}
local object_table_calls = {}

local original_notify = vim.notify
local original_input = vim.ui.input
local original_select = vim.ui.select

vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end

vim.ui.input = function(opts, callback)
  inputs[#inputs + 1] = opts
  callback("df")
end

vim.ui.select = function(items, opts, callback)
  selections[#selections + 1] = {
    items = items,
    opts = opts,
  }
  callback(items[1])
end

local root = {
  node_id = "",
  parent_id = "",
  name = "obj",
  path = "obj",
  depth = 0,
  type = "list",
  class = "list",
  length = 3,
  summary = "length 3",
  expandable = true,
  viewable_table = false,
  child_count = 3,
}

local nodes = {
  [""] = {
    {
      node_id = "1",
      parent_id = "",
      name = "alpha",
      path = "obj$alpha",
      depth = 1,
      type = "double",
      class = "numeric",
      length = 1,
      summary = "1",
      expandable = false,
      viewable_table = true,
      child_count = 0,
    },
    {
      node_id = "2",
      parent_id = "",
      name = "nested",
      path = "obj$nested",
      depth = 1,
      type = "list",
      class = "list",
      length = 1,
      summary = "length 1",
      expandable = true,
      viewable_table = false,
      child_count = 1,
    },
    {
      node_id = "3",
      parent_id = "",
      name = "tbl",
      path = "obj$tbl",
      depth = 1,
      type = "list",
      class = "data.frame",
      length = 2,
      summary = "2 x 2 data.frame",
      expandable = false,
      viewable_table = true,
      child_count = 0,
    },
  },
  ["2"] = {
    {
      node_id = "2/1",
      parent_id = "2",
      name = "df",
      path = "obj$nested$df",
      depth = 2,
      type = "list",
      class = "data.frame",
      length = 2,
      summary = "2 x 2 data.frame",
      expandable = false,
      viewable_table = true,
      child_count = 0,
    },
  },
}

local details = {
  [""] = "List of 3",
  ["1"] = "# numeric: 1 x 1\nvalue\n<double>\n1",
  ["2"] = "List of 1\n $ df:'data.frame': 2 obs. of 2 variables",
  ["3"] = "# data.frame: 2 x 2\nid         value\n<integer>  <character>\n1          a\n2          b",
  ["2/1"] = "# data.frame: 2 x 2\nid         value\n<integer>  <character>\n1          a\n2          b",
}

local table_opened = {
  kind = "table",
  session_id = "table-node-1",
  title = "df",
  source_label = "obj$nested$df",
  total_rows = 2,
  total_columns = 2,
  schema = {
    { index = 1, name = "id", class = "integer", type = "integer" },
    { index = 2, name = "value", class = "character", type = "character" },
  },
  sort = { column_index = 0, direction = "" },
  filters = {},
}

local lsp = {}

lsp.view_open = function()
  return {
    kind = "tree",
    session_id = "tree-session-1",
    title = "obj",
    source_label = "obj",
    root = root,
    total_children = 3,
  }
end

lsp.view_close = function(_opts, _bufnr, session_id)
  close_calls[#close_calls + 1] = session_id
  return { closed = true }
end

lsp.object_children = function(_opts, _bufnr, _session_id, node_id)
  return {
    session_id = "tree-session-1",
    node_id = node_id or "",
    total_children = #(nodes[node_id or ""] or {}),
    children = vim.deepcopy(nodes[node_id or ""] or {}),
  }
end

lsp.object_detail = function(_opts, _bufnr, _session_id, node_id)
  return {
    session_id = "tree-session-1",
    node_id = node_id or "",
    text = details[node_id or ""] or "",
  }
end

lsp.object_search = function()
  return {
    session_id = "tree-session-1",
    query = "df",
    matches = { vim.deepcopy(nodes["2"][1]) },
  }
end

lsp.object_table = function(_opts, _bufnr, _session_id, node_id)
  object_table_calls[#object_table_calls + 1] = node_id
  return vim.deepcopy(table_opened)
end

lsp.view_page = function(_opts, _bufnr, _session_id, offset, limit)
  local rows = {
    { "1", "a" },
    { "2", "b" },
  }
  return {
    offset = offset or 0,
    limit = limit or 0,
    total_rows = 2,
    row_numbers = { 1, 2 },
    rows = rows,
  }
end

lsp.view_sort = function()
  return table_opened
end
lsp.view_filter = function()
  return table_opened
end
lsp.view_values = function()
  return { values = {} }
end
lsp.view_profile = function()
  return { text = "" }
end
lsp.view_code = function()
  return { code = "" }
end
lsp.view_export = function()
  return { text = "" }
end
lsp.view_cell = function()
  return { text = "" }
end

local ok, err = pcall(function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_object_tree.R")
  vim.bo[source_buf].filetype = "r"

  local opened = require("ark.view").open({
    expr = "obj",
    source_bufnr = source_buf,
    options = {},
    lsp = lsp,
    notify = vim.notify,
  })
  if type(opened) ~= "table" or type(opened.tree_buf) ~= "number" then
    error("expected ArkView to dispatch list payload to object tree, got " .. vim.inspect(opened), 0)
  end

  local tree_tab = opened.tabpage
  local tree_win = opened.tree_win
  local tree_lines = vim.api.nvim_buf_get_lines(opened.tree_buf, 0, -1, false)
  if not table.concat(tree_lines, "\n"):find("+ nested <list>", 1, true) then
    error("expected collapsed nested list node, got " .. vim.inspect(tree_lines), 0)
  end
  if not table.concat(tree_lines, "\n"):find("[table]", 1, true) then
    error("expected table-viewable nodes to be marked before opening, got " .. vim.inspect(tree_lines), 0)
  end

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = opened.tree_buf,
    modeline = false,
  })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)

  tree_lines = vim.api.nvim_buf_get_lines(opened.tree_buf, 0, -1, false)
  if not table.concat(tree_lines, "\n"):find("df <data.frame>", 1, true) then
    error("expected Enter to expand nested list and reveal df, got " .. vim.inspect(tree_lines), 0)
  end

  vim.api.nvim_feedkeys("h", "xt", false)
  tree_lines = vim.api.nvim_buf_get_lines(opened.tree_buf, 0, -1, false)
  if table.concat(tree_lines, "\n"):find("df <data.frame>", 1, true) then
    error("expected h on expanded nested list to collapse df child, got " .. vim.inspect(tree_lines), 0)
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)

  vim.api.nvim_feedkeys("S", "xt", false)
  if #inputs ~= 1 or #selections ~= 1 then
    error("expected S to prompt and open a component picker, got inputs=" .. #inputs .. " selections=" .. #selections, 0)
  end
  local cursor = vim.api.nvim_win_get_cursor(tree_win)
  local selected = vim.api.nvim_buf_get_lines(opened.tree_buf, cursor[1] - 1, cursor[1], false)[1] or ""
  if not selected:find("df <data.frame>", 1, true) then
    error("expected S to jump to df component, got cursor line " .. vim.inspect(selected), 0)
  end

  local detail_text = table.concat(vim.api.nvim_buf_get_lines(opened.detail_buf, 0, -1, false), "\n")
  if not detail_text:find("# data.frame: 2 x 2", 1, true) then
    error("expected tibble-like data preview before opening table, got " .. detail_text, 0)
  end

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  if #object_table_calls ~= 1 or object_table_calls[1] ~= "2/1" then
    error("expected Enter on df to request nested table view, got " .. vim.inspect(object_table_calls), 0)
  end
  if vim.api.nvim_get_current_tabpage() == tree_tab then
    error("expected nested table ArkView to open in a new tab", 0)
  end
  local table_lines = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
  if not table_lines:find("id", 1, true) or not table_lines:find("value", 1, true) then
    error("expected regular ArkView table grid for nested df, got " .. table_lines, 0)
  end

  vim.api.nvim_feedkeys("q", "xt", false)
  if vim.api.nvim_get_current_tabpage() ~= tree_tab then
    error("expected quitting nested table to return to list exploration", 0)
  end
  if not vim.api.nvim_win_is_valid(tree_win) then
    error("expected tree window to remain valid after closing nested table", 0)
  end

  require("ark.view").close()
  if not vim.tbl_contains(close_calls, "tree-session-1") then
    error("expected closing object tree to close root view session, got " .. vim.inspect(close_calls), 0)
  end
end)

vim.notify = original_notify
vim.ui.input = original_input
vim.ui.select = original_select
stop_watchdog()

if not ok then
  ark_test.fail(err)
end

if #notifications ~= 0 then
  ark_test.fail("expected object tree happy path to avoid notifications, got " .. vim.inspect(notifications))
end
