local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_help_end_to_end.R"
local _, _client = ark_test.setup_managed_buffer(test_file, {
  "mean",
})

vim.api.nvim_win_set_cursor(0, { 1, 1 })

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

local ok, err = pcall(function()
  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkHelp")

  local help_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(help_buf, 0, math.min(15, vim.api.nvim_buf_line_count(help_buf)), false)

  if vim.bo[help_buf].filetype ~= "arkhelp" then
    error("expected ArkHelp to open an arkhelp buffer, got " .. tostring(vim.bo[help_buf].filetype), 0)
  end

  if vim.bo[help_buf].buftype ~= "nofile" then
    error("expected ArkHelp buffer to be nofile, got " .. tostring(vim.bo[help_buf].buftype), 0)
  end

  if lines[1] ~= "Arithmetic Mean" then
    error("unexpected ArkHelp title: " .. vim.inspect(lines), 0)
  end

  if lines[8] ~= "```r" or lines[9] ~= "     mean(x, ...)" then
    error("unexpected ArkHelp usage block: " .. vim.inspect(lines), 0)
  end

  if lines[15] ~= "Arguments:" then
    error("unexpected ArkHelp arguments header: " .. vim.inspect(lines), 0)
  end

  if #notifications ~= 0 then
    error("expected ArkHelp e2e happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end
end)

vim.notify = original_notify

if not ok then
  error(err, 0)
end
