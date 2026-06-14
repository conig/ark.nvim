local log_path = vim.env.ARK_TUI_TRACE_LOG or "/tmp/ark_tui_blink_trace.log"
vim.fn.writefile({}, log_path)

local function append(value)
  value.ts_ms = math.floor(vim.loop.hrtime() / 1e6)
  vim.fn.writefile({ vim.json.encode(value) }, log_path, "a")
end

local function snapshot(label, extra)
  local ok_blink, blink = pcall(require, "blink.cmp")
  local ok_list, list = pcall(require, "blink.cmp.completion.list")
  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
  local items = {}
  local menu_lines = {}
  local menu_open = false
  local diagnostics = {}
  local ark_status = {}

  if ok_list and list and list.items then
    for _, item in ipairs(list.items) do
      items[#items + 1] = {
        label = item.label,
        kind = item.kind,
        source_id = item.source_id,
        source_name = item.source_name,
        client_name = item.client_name,
      }
    end
  end

  if ok_menu and menu and menu.win and type(menu.win.get_win) == "function" then
    menu_open = menu.win:get_win() ~= nil
    if type(menu.win.get_buf) == "function" then
      local menu_buf = menu.win:get_buf()
      if vim.api.nvim_buf_is_valid(menu_buf) then
        menu_lines = vim.api.nvim_buf_get_lines(menu_buf, 0, math.min(3, vim.api.nvim_buf_line_count(menu_buf)), false)
      end
    end
  end

  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    diagnostics[#diagnostics + 1] = {
      message = diagnostic.message,
      lnum = diagnostic.lnum,
      col = diagnostic.col,
      end_lnum = diagnostic.end_lnum,
      end_col = diagnostic.end_col,
      severity = diagnostic.severity,
    }
  end

  local ok_ark, ark = pcall(require, "ark")
  if ok_ark and ark and type(ark.status) == "function" then
    local ok_status, status = pcall(ark.status, { include_lsp = true })
    if ok_status and type(status) == "table" then
      local lsp_status = type(status.lsp_status) == "table" and status.lsp_status or {}
      ark_status = {
        bridge_ready = status.bridge_ready == true,
        repl_ready = status.repl_ready == true,
        lsp_available = lsp_status.available == true,
        console_scope_count = tonumber(lsp_status.consoleScopeCount or 0) or 0,
        library_path_count = tonumber(lsp_status.libraryPathCount or 0) or 0,
      }
    end
  end

  append(vim.tbl_extend("force", {
    label = label,
    mode = vim.api.nvim_get_mode().mode,
    line = vim.api.nvim_get_current_line(),
    cursor = vim.api.nvim_win_get_cursor(0),
    ark_clients = #(vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" }) or {}),
    ark_status = ark_status,
    visible = ok_blink and blink.is_visible() or false,
    menu_open = menu_open,
    menu_lines = menu_lines,
    trigger = ok_trigger and trigger and trigger.context and trigger.context.trigger or nil,
    items = items,
    diagnostics = diagnostics,
  }, extra or {}))
end

local ok_ark_blink, ark_blink = pcall(require, "ark.blink")
if ok_ark_blink and ark_blink and type(ark_blink.handle_insert_char_pre) == "function" then
  local base_handle_insert_char_pre = ark_blink.handle_insert_char_pre
  ark_blink.handle_insert_char_pre = function(bufnr, char)
    char = char or vim.v.char
    if char == "$" or char == "@" then
      snapshot("ArkHandleInsertCharPre:before", {
        char = char,
      })
    end
    local result = base_handle_insert_char_pre(bufnr, char)
    if char == "$" or char == "@" then
      snapshot("ArkHandleInsertCharPre:after", {
        char = char,
      })
    end
    return result
  end
end

vim.api.nvim_create_autocmd({ "InsertEnter", "InsertLeave", "InsertCharPre", "TextChangedI", "CursorMovedI" }, {
  callback = function(args)
    snapshot(args.event, {
      char = args.event == "InsertCharPre" and vim.v.char or nil,
      ark_clients = #(vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" }) or {}),
    })
  end,
})

vim.api.nvim_create_autocmd("DiagnosticChanged", {
  callback = function()
    snapshot("DiagnosticChanged")
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = { "BlinkCmpShow", "BlinkCmpHide" },
  callback = function(args)
    snapshot(args.match, {
      user_event = args.match,
    })
  end,
})

vim.api.nvim_create_user_command("ArkTraceSnapshot", function(opts)
  snapshot("ArkTraceSnapshot", { args = opts.args })
end, { nargs = "*" })

vim.api.nvim_create_user_command("ArkTraceClearInput", function()
  local input_start = 0
  local ok_console, console = pcall(require, "ark.console")
  if ok_console and console and type(console.status) == "function" then
    local status = console.status(0)
    input_start = type(status) == "table" and tonumber(status.input_start) or 0
  end
  vim.api.nvim_buf_set_lines(0, input_start or 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { (input_start or 0) + 1, 0 })
  snapshot("ArkTraceClearInput")
  vim.cmd("startinsert")
end, {})

vim.api.nvim_create_user_command("ArkTraceSend", function(opts)
  local ok_ark, ark = pcall(require, "ark")
  local sent, err = nil, nil
  if ok_ark and ark and type(ark.send) == "function" then
    sent, err = ark.send(opts.args)
  else
    err = "ark.nvim send API is unavailable"
  end
  snapshot("ArkTraceSend", {
    args = opts.args,
    sent = sent == true,
    err = err,
  })
end, { nargs = "+" })

vim.api.nvim_create_user_command("ArkTraceAccept", function(opts)
  local ok_blink, blink = pcall(require, "blink.cmp")
  local index = tonumber(opts.args)
  snapshot("ArkTraceAccept:before", {
    index = index,
  })
  if ok_blink and blink then
    blink.accept({
      force = true,
      index = index,
    })
  end
  vim.defer_fn(function()
    snapshot("ArkTraceAccept:after", {
      index = index,
    })
  end, 20)
end, { nargs = 1 })

local function trace_accept(opts)
  local ok_blink, blink = pcall(require, "blink.cmp")
  local index = opts and opts.index or nil
  local label = opts and opts.label or nil
  local resolved_index = index
  if ok_blink and blink and label ~= nil then
    local ok_list, list = pcall(require, "blink.cmp.completion.list")
    if ok_list and list and type(list.items) == "table" then
      for item_index, item in ipairs(list.items) do
        if item.label == label then
          resolved_index = item_index
          break
        end
      end
    end
  end
  snapshot("ArkTraceAcceptKey:before", {
    index = resolved_index,
    label = label,
  })
  if ok_blink and blink and resolved_index ~= nil then
    blink.accept({
      force = true,
      index = resolved_index,
    })
  end
  vim.defer_fn(function()
    snapshot("ArkTraceAcceptKey:after", {
      index = resolved_index,
      label = label,
    })
  end, 20)
end

vim.keymap.set("i", "<C-G>", function()
  trace_accept({ label = "mpg" })
end, { buffer = 0 })

vim.keymap.set("i", "<C-T>", function()
  trace_accept({ label = "drat" })
end, { buffer = 0 })

local function trace_select_next()
  local ok_blink, blink = pcall(require, "blink.cmp")
  snapshot("ArkTraceSelectNext:before")
  if ok_blink and blink then
    blink.select_next()
  end
  vim.defer_fn(function()
    snapshot("ArkTraceSelectNext:after")
  end, 20)
end

vim.keymap.set("i", "<C-J>", function()
  trace_select_next()
end, { buffer = 0 })

local function trace_show_trigger(trigger_character)
  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  snapshot("ArkTraceShowTrigger:before", {
    trigger_character = trigger_character,
  })
  if ok_trigger and trigger and type(trigger.show) == "function" then
    trigger.show({
      trigger_kind = "trigger_character",
      trigger_character = trigger_character,
    })
  end
  vim.defer_fn(function()
    snapshot("ArkTraceShowTrigger:after", {
      trigger_character = trigger_character,
    })
  end, 20)
end

vim.api.nvim_create_user_command("ArkTraceShowTrigger", function(opts)
  vim.cmd("startinsert")
  vim.defer_fn(function()
    trace_show_trigger(opts.args)
  end, 20)
end, { nargs = 1 })

vim.keymap.set("i", "<C-Q>", function()
  trace_show_trigger('"')
end, { buffer = 0 })

vim.keymap.set("i", "<C-X>", function()
  trace_show_trigger("/")
end, { buffer = 0 })

vim.keymap.set("i", "<F5>", function()
  trace_show_trigger('"')
end, { buffer = 0 })

vim.keymap.set("i", "<F6>", function()
  trace_show_trigger("/")
end, { buffer = 0 })

snapshot("loaded")
