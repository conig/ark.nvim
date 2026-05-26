vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local root = vim.fn.getcwd()
local target_dir = root .. "/target/debug"
local built_binary = target_dir .. "/ark-lsp"

vim.fn.mkdir(target_dir, "p")
local built_binary_existed = vim.fn.filereadable(built_binary) == 1
if not built_binary_existed then
  vim.fn.writefile({ "# fake ark-lsp binary for build-float close test" }, built_binary)
end

local original_jobstart = vim.fn.jobstart

local job_opts = nil

vim.fn.jobstart = function(cmd, opts)
  if not vim.deep_equal(cmd, { "cargo", "build", "-p", "ark-lsp" }) then
    error("unexpected build command: " .. vim.inspect(cmd), 0)
  end
  job_opts = opts
  return 4242
end

local function build_float()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:find("ark.nvim is rebuilding detached ark-lsp.", 1, true) then
        return win, buf, text
      end
    end
  end
  return nil, nil, nil
end

local function build_log_buffer_text()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:find("ark.nvim is rebuilding detached ark-lsp.", 1, true) then
        return text
      end
    end
  end
  return ""
end

local ok, err = pcall(function()
  local dev = require("ark.dev")

  local started, start_err = dev.build_detached_lsp({
    show_output = true,
  })
  if not started then
    error("failed to start detached ark-lsp rebuild: " .. tostring(start_err), 0)
  end

  local job_started = vim.wait(1000, function()
    return job_opts ~= nil
  end, 20, false)
  if not job_started then
    error("timed out waiting for detached ark-lsp rebuild job", 0)
  end

  -- A successful visible rebuild should not leave users staring at a silent
  -- build float. Keep the hidden log buffer for history, but dismiss the UI.
  local win, _, text = build_float()
  if not win then
    error("expected detached ark-lsp rebuild to open a floating log window", 0)
  end
  if not text:find("$ cargo build -p ark-lsp", 1, true) then
    error("expected build float to show cargo command: " .. vim.inspect(text), 0)
  end

  job_opts.on_stdout(4242, { "    Finished dev [unoptimized] target(s)", "" })
  job_opts.on_exit(4242, 0)

  local closed = vim.wait(1000, function()
    return build_float() == nil
  end, 20, false)
  if not closed then
    local _, _, current_text = build_float()
    error("expected successful rebuild to close build float, got " .. vim.inspect(current_text), 0)
  end

  local final_text = build_log_buffer_text()
  if not final_text:find("detached ark-lsp rebuilt", 1, true) then
    error("expected hidden build log buffer to record ready status: " .. vim.inspect(final_text), 0)
  end
end)

vim.fn.jobstart = original_jobstart
if not built_binary_existed then
  vim.fn.delete(built_binary)
end

if not ok then
  error(err, 0)
end
