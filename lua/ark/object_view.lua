local M = {}

local states = {}
local ns = vim.api.nvim_create_namespace("ark-object-view")

local function valid_tab(tabpage)
  return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function current_state()
  return states[vim.api.nvim_get_current_tabpage()]
end

local function notify(state, message, level)
  local fn = state and state.notify
  if type(fn) == "function" then
    fn(message, level)
    return
  end
  vim.notify(message, level or vim.log.levels.INFO, { title = "ark.nvim" })
end

local function new_scratch_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  if type(filetype) == "string" and filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

local function set_buffer_lines(buf, lines)
  if not valid_buf(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

local function node_id(node)
  return tostring((node or {}).node_id or "")
end

local function node_label(node)
  local name = tostring((node or {}).name or "")
  if name == "" then
    name = "(unnamed)"
  end
  return name
end

local function node_type_label(node)
  local class = tostring((node or {}).class or "")
  local kind = tostring((node or {}).type or "")
  if class ~= "" and class ~= kind then
    return "<" .. class .. ">"
  end
  if kind ~= "" then
    return "<" .. kind .. ">"
  end
  return "<unknown>"
end

local function request_or_error(state, title, fn, ...)
  if type(fn) ~= "function" then
    local err = title .. " endpoint is unavailable"
    notify(state, err, vim.log.levels.WARN)
    return nil, err
  end

  local result, err = fn(state.options, state.source_bufnr, ...)
  if err then
    notify(state, err, vim.log.levels.WARN)
    return nil, err
  end
  return result, nil
end

local function render_details(state, title, text)
  local lines = { title or "Object", "" }
  if type(text) == "string" and text ~= "" then
    vim.list_extend(lines, vim.split(text, "\n", { plain = true, trimempty = false }))
  else
    lines[#lines + 1] = "No details."
  end
  set_buffer_lines(state.detail_buf, lines)
end

local function fetch_children(state, id)
  id = tostring(id or "")
  if state.children[id] ~= nil then
    return state.children[id]
  end

  local payload = request_or_error(state, "ArkObject", state.lsp.object_children, state.session_id, id, 0, 0)
  if not payload then
    state.children[id] = {}
    return state.children[id]
  end

  state.children[id] = payload.children or {}
  return state.children[id]
end

local function render_tree(state)
  local lines = {}
  local nodes = {}
  local line_by_id = {}

  local function add(node)
    local id = node_id(node)
    local depth = tonumber(node.depth or 0) or 0
    local expandable = node.expandable == true
    local expanded = state.expanded[id] == true
    local marker = " "
    if expandable then
      marker = expanded and "-" or "+"
    end
    local table_marker = node.viewable_table == true and " [table]" or ""
    local summary = tostring(node.summary or "")
    local suffix = summary ~= "" and ("  " .. summary) or ""
    local line = string.rep("  ", depth) .. marker .. " " .. node_label(node) .. " " .. node_type_label(node) .. table_marker .. suffix
    lines[#lines + 1] = line
    nodes[#lines] = node
    line_by_id[id] = #lines

    if expandable and expanded then
      for _, child in ipairs(fetch_children(state, id)) do
        add(child)
      end
    end
  end

  add(state.root)
  state.visible_nodes = nodes
  state.line_by_id = line_by_id
  set_buffer_lines(state.tree_buf, lines)

  if valid_buf(state.tree_buf) then
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, 0, -1)
    for index, line in ipairs(lines) do
      local marker_col = line:find("[+-]", 1)
      if marker_col then
        vim.api.nvim_buf_set_extmark(state.tree_buf, ns, index - 1, marker_col - 1, {
          end_col = marker_col,
          hl_group = "Identifier",
        })
      end
      local table_col = line:find("[table]", 1, true)
      if table_col then
        vim.api.nvim_buf_set_extmark(state.tree_buf, ns, index - 1, table_col - 1, {
          end_col = table_col + 6,
          hl_group = "Comment",
        })
      end
    end
  end
end

local function selected_node(state)
  if not valid_win(state.tree_win) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.tree_win)[1]
  return (state.visible_nodes or {})[line]
end

local function show_node_detail(state, node)
  if not node then
    return
  end
  local id = node_id(node)
  local detail = state.details[id]
  if detail == nil then
    detail = request_or_error(state, "ArkObject", state.lsp.object_detail, state.session_id, id)
    state.details[id] = detail or false
  end
  if detail == false then
    render_details(state, node_label(node), node.summary or "")
    return
  end
  render_details(state, node_label(node), detail.text or node.summary or "")
end

local function sync_detail_to_cursor(state)
  local node = selected_node(state)
  if not node then
    return
  end
  local id = node_id(node)
  if state.selected_node_id == id then
    return
  end
  state.selected_node_id = id
  show_node_detail(state, node)
end

local function focus_node(state, id)
  render_tree(state)
  local line = (state.line_by_id or {})[tostring(id or "")]
  if line and valid_win(state.tree_win) then
    vim.api.nvim_set_current_win(state.tree_win)
    vim.api.nvim_win_set_cursor(state.tree_win, { line, 0 })
    state.selected_node_id = nil
    sync_detail_to_cursor(state)
  end
end

local function ancestor_ids(id)
  id = tostring(id or "")
  if id == "" then
    return {}
  end
  local parts = vim.split(id, "/", { plain = true })
  local out = {}
  for index = 1, #parts - 1 do
    out[#out + 1] = table.concat(vim.list_slice(parts, 1, index), "/")
  end
  return out
end

local function expand_to_node(state, id)
  state.expanded[""] = true
  for _, ancestor in ipairs(ancestor_ids(id)) do
    state.expanded[ancestor] = true
    fetch_children(state, ancestor)
  end
  focus_node(state, id)
end

local function toggle_node(state, node)
  if not node or node.expandable ~= true then
    return false
  end
  local id = node_id(node)
  state.expanded[id] = not state.expanded[id]
  if state.expanded[id] then
    fetch_children(state, id)
  end
  focus_node(state, id)
  return true
end

local function table_proxy(state, node)
  local proxy = {}
  setmetatable(proxy, {
    __index = state.lsp,
  })
  proxy.view_open = function(_options, _source_bufnr)
    return state.lsp.object_table(state.options, state.source_bufnr, state.session_id, node_id(node))
  end
  return proxy
end

local function open_table_node(state, node)
  if not node or node.viewable_table ~= true then
    return false
  end

  local tree_tab = state.tabpage
  local tree_win = state.tree_win
  local opened, err = require("ark.view").open({
    expr = node.path or node_label(node),
    source_bufnr = state.source_bufnr,
    options = state.options,
    lsp = table_proxy(state, node),
    notify = state.notify,
    on_close = function()
      if valid_tab(tree_tab) then
        vim.api.nvim_set_current_tabpage(tree_tab)
        if valid_win(tree_win) then
          vim.api.nvim_set_current_win(tree_win)
        end
      end
    end,
  })
  if not opened then
    notify(state, err or "failed to open nested table", vim.log.levels.WARN)
    return false
  end
  return true
end

local function activate_node(state)
  local node = selected_node(state)
  if not node then
    return
  end
  if node.viewable_table == true then
    open_table_node(state, node)
    return
  end
  if node.expandable == true then
    toggle_node(state, node)
    return
  end
  show_node_detail(state, node)
end

local function close_tab(state)
  if not state or state.closing then
    return
  end
  state.closing = true
  pcall(state.lsp.view_close, state.options, state.source_bufnr, state.session_id)
  states[state.tabpage] = nil
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  local on_close = state.on_close
  if valid_tab(state.tabpage) then
    vim.api.nvim_set_current_tabpage(state.tabpage)
    vim.cmd("tabclose")
  end
  if type(on_close) == "function" then
    pcall(on_close)
  end
end

local function close_from_owner(state)
  close_tab(state)
end

local function search_nodes(state)
  vim.ui.input({
    prompt = "ArkObject component: ",
  }, function(input)
    if input == nil then
      return
    end

    local payload = request_or_error(state, "ArkObject", state.lsp.object_search, state.session_id, input, 1000, 100)
    if not payload then
      return
    end

    local items = payload.matches or {}
    if #items == 0 then
      notify(state, "No matching object components", vim.log.levels.INFO)
      return
    end

    local function choose(item)
      if not item then
        return
      end
      expand_to_node(state, node_id(item))
    end

    local ok, snacks = pcall(require, "snacks")
    if ok and type(snacks) == "table" and type(snacks.picker) == "table" and type(snacks.picker.select) == "function" then
      snacks.picker.select(items, {
        prompt = "ArkObject Components",
        format_item = function(item)
          return string.format("%s %s - %s", item.path or item.name or "", node_type_label(item), item.summary or "")
        end,
      }, choose)
      return
    end

    vim.ui.select(items, {
      prompt = "ArkObject Components",
      format_item = function(item)
        return string.format("%s %s - %s", item.path or item.name or "", node_type_label(item), item.summary or "")
      end,
    }, choose)
  end)
end

local function setup_keymaps(state)
  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = state.tree_buf, nowait = true, silent = true })
  end

  for _, lhs in ipairs({ "i", "I", "a", "A", "o", "O", "R", "x", "X", "D" }) do
    map(lhs, function() end)
  end
  map("q", function()
    close_tab(state)
  end)
  map("<CR>", function()
    activate_node(state)
  end)
  map("l", function()
    local node = selected_node(state)
    if node and node.viewable_table == true then
      open_table_node(state, node)
    elseif node and node.expandable == true and state.expanded[node_id(node)] ~= true then
      toggle_node(state, node)
    end
  end)
  map("h", function()
    local node = selected_node(state)
    if not node then
      return
    end
    local id = node_id(node)
    if state.expanded[id] == true then
      toggle_node(state, node)
      return
    end
    local parent = tostring(node.parent_id or "")
    if parent ~= id then
      focus_node(state, parent)
    end
  end)
  map("za", function()
    toggle_node(state, selected_node(state))
  end)
  map("S", function()
    search_nodes(state)
  end)
  map("r", function()
    local opened = request_or_error(state, "ArkObject", state.lsp.view_open, state.expr)
    if not opened or opened.kind ~= "tree" then
      notify(state, "ArkObject refresh no longer returned a list tree", vim.log.levels.WARN)
      return
    end
    local old_session = state.session_id
    state.session_id = opened.session_id
    state.title = opened.title or state.expr
    state.root = opened.root or state.root
    state.children = {}
    state.details = {}
    state.expanded = { [""] = true }
    state.selected_node_id = nil
    pcall(state.lsp.view_close, state.options, state.source_bufnr, old_session)
    fetch_children(state, "")
    focus_node(state, "")
  end)
end

function M.open(opts, opened)
  opts = opts or {}
  opened = opened or {}
  if opened.kind ~= "tree" then
    return nil, "object view requires a tree payload"
  end

  local source_tab = vim.api.nvim_get_current_tabpage()
  local tree_buf = new_scratch_buffer("")
  local detail_buf = new_scratch_buffer("markdown")

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tree_win, tree_buf)
  vim.wo[tree_win].wrap = false
  vim.wo[tree_win].number = false
  vim.wo[tree_win].relativenumber = false
  vim.wo[tree_win].cursorline = true
  vim.wo[tree_win].cursorlineopt = "line"

  vim.cmd("rightbelow 52vsplit")
  local detail_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(detail_win, detail_buf)
  vim.wo[detail_win].wrap = false
  vim.wo[detail_win].number = false
  vim.wo[detail_win].relativenumber = false
  vim.wo[detail_win].cursorline = false
  vim.api.nvim_set_current_win(tree_win)

  local state = {
    expr = opts.expr or opened.source_label or "",
    source_bufnr = opts.source_bufnr,
    source_tab = source_tab,
    options = opts.options or {},
    lsp = opts.lsp,
    notify = opts.notify,
    on_close = opts.on_close,
    session_id = opened.session_id,
    title = opened.title or opts.expr or "ArkObject",
    root = opened.root or {
      node_id = "",
      name = opened.title or opts.expr or "ArkObject",
      expandable = true,
      child_count = opened.total_children or 0,
      depth = 0,
    },
    tabpage = tabpage,
    tree_buf = tree_buf,
    tree_win = tree_win,
    detail_buf = detail_buf,
    detail_win = detail_win,
    expanded = { [""] = true },
    children = {},
    details = {},
    visible_nodes = {},
    line_by_id = {},
  }
  states[tabpage] = state

  local group = vim.api.nvim_create_augroup("ArkObjectView" .. tostring(tabpage), { clear = true })
  state.augroup = group
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = tree_buf,
    callback = function()
      sync_detail_to_cursor(state)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = tree_buf,
    callback = function()
      close_from_owner(state)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(tree_win),
    callback = function()
      close_from_owner(state)
    end,
  })

  setup_keymaps(state)
  fetch_children(state, "")
  render_tree(state)
  render_details(state, "ArkObject", "Loading preview...")
  focus_node(state, "")
  pcall(vim.cmd, "stopinsert")
  return state
end

function M.refresh()
  local state = current_state()
  if not state then
    return nil, "ArkObject is not open in the current tab"
  end
  local opened = request_or_error(state, "ArkObject", state.lsp.view_open, state.expr)
  if not opened or opened.kind ~= "tree" then
    return nil, "ArkObject refresh no longer returned a list tree"
  end
  local old_session = state.session_id
  state.session_id = opened.session_id
  state.root = opened.root or state.root
  state.children = {}
  state.details = {}
  state.expanded = { [""] = true }
  pcall(state.lsp.view_close, state.options, state.source_bufnr, old_session)
  fetch_children(state, "")
  focus_node(state, "")
  return state
end

function M.close()
  local state = current_state()
  if not state then
    return nil, "ArkObject is not open in the current tab"
  end
  close_tab(state)
  return true
end

function M.is_open()
  return current_state() ~= nil
end

return M
