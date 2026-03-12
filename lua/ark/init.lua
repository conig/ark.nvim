local blink = require("ark.blink")
local config = require("ark.config")
local lsp = require("ark.lsp")
local tmux = require("ark.tmux")

local M = {}

local did_setup = false
local options = nil
local startup_tokens = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ark.nvim" })
end

local function merged_opts(base, opts)
  return vim.tbl_deep_extend("force", config.defaults(), base or {}, opts or {})
end

local function ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

function M.setup(opts)
  options = merged_opts(options, opts)

  local group = vim.api.nvim_create_augroup("ArkNvim", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = options.filetypes,
    callback = function(args)
      local token = (startup_tokens[args.buf] or 0) + 1
      startup_tokens[args.buf] = token

      local function start_buffer()
        if startup_tokens[args.buf] ~= token then
          return
        end
        if not vim.api.nvim_buf_is_valid(args.buf) then
          return
        end
        if not vim.tbl_contains(options.filetypes, vim.bo[args.buf].filetype) then
          return
        end

        if options.auto_start_pane then
          local _, pane_err = tmux.start(options)
          if pane_err then
            notify(pane_err, vim.log.levels.WARN)
          end
        end

        if options.auto_start_lsp then
          if options.async_startup then
            lsp.start_async(options, args.buf)
          else
            lsp.start(options, args.buf)
          end
        end
      end

      if options.async_startup then
        vim.defer_fn(start_buffer, 20)
      else
        start_buffer()
      end
    end,
    desc = "Start ark.nvim pane and LSP for R-family buffers",
  })

  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    pattern = options.filetypes,
    callback = function(args)
      blink.record_insert_char(args.buf)
    end,
    desc = "Track opening-pair insertions for Ark completion recovery",
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    pattern = options.filetypes,
    callback = function(args)
      blink.maybe_show_after_pair(args.buf)
    end,
    desc = "Re-show Blink completion after autopairs inserts closing delimiters",
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    pattern = options.filetypes,
    callback = function(args)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          blink.maybe_show_after_pair(args.buf)
        end
      end)
    end,
    desc = "Recover Blink completion after autopairs text changes in R buffers",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      tmux.stop()
    end,
    desc = "Stop ark.nvim managed tmux pane on exit",
  })

  did_setup = true
  return options
end

function M.options()
  ensure_setup()
  return options
end

function M.pane_command()
  ensure_setup()
  return tmux.pane_command(options.tmux)
end

function M.start_pane()
  ensure_setup()
  local pane_id, err = tmux.start(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  notify("managed R pane ready: " .. pane_id)
  return pane_id
end

function M.restart_pane()
  ensure_setup()
  local pane_id, err = tmux.restart(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  notify("managed R pane restarted: " .. pane_id)
  return pane_id
end

function M.stop_pane()
  ensure_setup()
  tmux.stop()
  notify("managed R pane stopped")
end

function M.start_lsp(bufnr)
  ensure_setup()
  return lsp.start(options, bufnr)
end

function M.refresh(bufnr)
  ensure_setup()

  if options.auto_start_pane then
    local _, pane_err = tmux.start(options)
    if pane_err then
      notify(pane_err, vim.log.levels.WARN)
    end
  end

  return lsp.restart(options, bufnr)
end

function M.lsp_config(bufnr)
  ensure_setup()
  return lsp.config(options, bufnr)
end

function M.status()
  ensure_setup()
  local status = tmux.status(options.tmux)
  status.lsp_cmd = options.lsp.cmd
  status.launcher = options.tmux.launcher
  return status
end

return M
