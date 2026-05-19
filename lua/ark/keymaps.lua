local M = {}

local group_name = "ArkKeymaps"

local function normalize_opts(opts)
  local raw = opts and opts.keymaps or nil
  if raw == true then
    raw = { enabled = true }
  elseif type(raw) ~= "table" then
    raw = {}
  end

  return {
    enabled = raw.enabled == true,
    filetypes = opts and opts.filetypes or { "r", "rmd", "qmd", "quarto" },
    prefix = type(raw.prefix) == "string" and raw.prefix ~= "" and raw.prefix or "<leader>r",
    target_prefix = type(raw.target_prefix) == "string" and raw.target_prefix ~= "" and raw.target_prefix
      or "<leader>t",
    snippets = type(raw.snippets) == "string" and raw.snippets ~= "" and raw.snippets or "<leader>as",
  }
end

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "ark.nvim" })
end

local function current_expr()
  return require("ark.expression").current()
end

local function ark()
  local ok, module = pcall(require, "ark")
  if not ok then
    notify("ark.nvim is not available", vim.log.levels.ERROR)
    return nil
  end
  return module
end

local function send_expr(expr)
  if type(expr) ~= "string" or expr == "" then
    notify("No R expression found to send")
    return
  end

  local module = ark()
  if not module then
    return
  end

  local ok, err = module.send(expr)
  if not ok then
    notify(err or "failed to send expression to Ark session", vim.log.levels.ERROR)
  end
end

local function send_current_expr()
  send_expr(current_expr())
end

local function call_on_current_expr(fn_name)
  return function()
    local expr = current_expr()
    if not expr then
      notify("No R expression found under cursor")
      return
    end
    send_expr(string.format("%s(%s)", fn_name, expr))
  end
end

local function start_or_restart_pane()
  local module = ark()
  if not module then
    return
  end

  local status = type(module.status) == "function" and module.status() or nil
  local pane_id = nil
  if type(status) == "table" and status.pane_exists == true then
    pane_id = module.restart_pane()
  else
    pane_id = module.start_pane()
  end

  if pane_id and type(module.refresh) == "function" then
    module.refresh(0)
  end
end

local function slimetree()
  local ok, module = pcall(require, "nvim-slimetree")
  if not ok or type(module) ~= "table" or type(module.slimetree) ~= "table" then
    notify("nvim-slimetree is not available", vim.log.levels.ERROR)
    return nil
  end
  return module.slimetree
end

local function send_current_form(opts)
  return function()
    local st = slimetree()
    if st and type(st.send_current) == "function" then
      st.send_current(opts)
    end
  end
end

local function send_current_line()
  local st = slimetree()
  if st and type(st.send_line) == "function" then
    st.send_line()
  end
end

local function map(bufnr, mode, lhs, rhs, desc, opts)
  opts = vim.tbl_extend("force", {
    buffer = bufnr,
    desc = desc,
    noremap = true,
    silent = true,
  }, opts or {})
  if opts.remap == true then
    opts.noremap = nil
  end
  vim.keymap.set(mode, lhs, rhs, opts)
end

function M.attach(bufnr, opts)
  opts = normalize_opts(opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) or not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return
  end

  if vim.b[bufnr].ark_recommended_keymaps_attached then
    return
  end

  local prefix = opts.prefix
  local target_prefix = opts.target_prefix

  map(bufnr, "n", "<CR>", send_current_form(), "Send current R form")
  map(bufnr, "n", "<leader><CR>", send_current_form({ hold_position = true }), "Send current R form and hold cursor")
  map(bufnr, "n", "<C-c><C-c>", send_current_line, "Send current R line")
  map(bufnr, "x", "<CR>", "<Plug>SlimeRegionSend", "Send selected R region", { remap = true })

  map(bufnr, "n", prefix .. "p", start_or_restart_pane, "Start or restart Ark R pane")
  map(bufnr, "n", prefix .. "R", function()
    local module = ark()
    if module then
      module.refresh(0)
    end
  end, "Refresh Ark LSP session")
  map(bufnr, "n", prefix .. "S", function()
    local module = ark()
    if module then
      vim.print(module.status({ include_lsp = true }))
    end
  end, "Show Ark status")

  map(bufnr, "n", prefix .. "=", function()
    local module = ark()
    if module then
      module.new_tab()
    end
  end, "New Ark R tab")
  map(bufnr, "n", prefix .. "[", function()
    local module = ark()
    if module then
      module.prev_tab()
    end
  end, "Previous Ark R tab")
  map(bufnr, "n", prefix .. "]", function()
    local module = ark()
    if module then
      module.next_tab()
    end
  end, "Next Ark R tab")
  map(bufnr, "n", prefix .. "-", function()
    local module = ark()
    if module then
      module.close_tab()
    end
  end, "Close Ark R tab")

  map(bufnr, { "n", "x" }, prefix .. "w", send_current_expr, "Send R expression or selection")
  map(bufnr, { "n", "x" }, prefix .. "h", call_on_current_expr("head"), "Run head() on R expression or selection")
  map(bufnr, { "n", "x" }, prefix .. "s", call_on_current_expr("summary"), "Run summary() on R expression or selection")

  map(bufnr, "n", prefix .. "V", function()
    local module = ark()
    if module then
      module.view(nil, 0)
    end
  end, "Open ArkView under cursor")
  map(bufnr, "n", prefix .. "?", function()
    local module = ark()
    if module then
      module.help(0)
    end
  end, "Open Ark help")
  map(bufnr, "n", opts.snippets, function()
    local module = ark()
    if module then
      module.snippets(0)
    end
  end, "Open Ark snippets")

  map(bufnr, "n", target_prefix .. "ta", function()
    local module = ark()
    if module then
      module.targets_pick(0)
    end
  end, "Acquire active Ark target")

  map(bufnr, "n", target_prefix .. "tn", function()
    local module = ark()
    if not module then
      return
    end
    local name, err = module.targets_active(0)
    if name then
      notify("Active target: " .. name, vim.log.levels.INFO)
    else
      notify(err or "No active target set.", vim.log.levels.WARN)
    end
  end, "Show active Ark target")

  vim.b[bufnr].ark_recommended_keymaps_attached = true
end

function M.setup(opts)
  opts = normalize_opts(opts)
  local group = vim.api.nvim_create_augroup(group_name, { clear = true })

  if not opts.enabled then
    return
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = opts.filetypes,
    callback = function(args)
      M.attach(args.buf, { filetypes = opts.filetypes, keymaps = opts })
    end,
    desc = "Attach optional ark.nvim recommended keymaps",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(bufnr) and filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    M.attach(bufnr, { filetypes = opts.filetypes, keymaps = opts })
  end
end

return M
