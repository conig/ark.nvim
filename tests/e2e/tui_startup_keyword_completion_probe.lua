_G.__ark_startup_keyword_completion_state = function()
  local state = {
    probe_loaded = true,
    mode = vim.api.nvim_get_mode().mode,
    line = vim.api.nvim_get_current_line(),
    cursor = vim.api.nvim_win_get_cursor(0),
    blink_loaded = false,
    blink_visible = false,
    blink_labels = {},
    lsp_labels = {},
    status = {},
  }

  local ok_blink, blink = pcall(require, "blink.cmp")
  state.blink_loaded = ok_blink
  if ok_blink and blink then
    state.blink_visible = blink.is_visible()
  end

  local ok_list, list = pcall(require, "blink.cmp.completion.list")
  if ok_list and list and type(list.items) == "table" then
    for _, item in ipairs(list.items) do
      state.blink_labels[#state.blink_labels + 1] = item.label
    end
  end

  local ok_ark, ark = pcall(require, "ark")
  if ok_ark and ark and type(ark.status) == "function" then
    local ok_status, status = pcall(ark.status, { include_lsp = true })
    if ok_status and type(status) == "table" then
      local lsp_status = type(status.lsp_status) == "table" and status.lsp_status or {}
      state.status = {
        bridge_ready = status.bridge_ready == true,
        repl_ready = status.repl_ready == true,
        lsp_available = lsp_status.available == true,
        console_scope_count = tonumber(lsp_status.consoleScopeCount or 0) or 0,
        library_path_count = tonumber(lsp_status.libraryPathCount or 0) or 0,
        main_buffer_unlocked = type(status.startup) == "table" and status.startup.main_buffer_unlocked == true
          or false,
      }
    end
  end

  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  if client then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local response = client:request_sync("textDocument/completion", {
      textDocument = vim.lsp.util.make_text_document_params(0),
      position = {
        line = cursor[1] - 1,
        character = cursor[2],
      },
      context = {
        triggerKind = 1,
      },
    }, 10000, 0)

    if response and response.result then
      local items = vim.islist(response.result) and response.result or (response.result.items or {})
      for _, item in ipairs(items) do
        state.lsp_labels[#state.lsp_labels + 1] = item.label
      end
    end
  end

  return vim.json.encode(state)
end
