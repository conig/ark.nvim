local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_help_end_to_end.R"
local _, _client = ark_test.setup_managed_buffer(test_file, {
  "mean",
}, {
  help = {
    display = "float",
  },
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
  local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)

  if vim.bo[help_buf].filetype ~= "markdown" then
    error("expected ArkHelp to open a markdown buffer, got " .. tostring(vim.bo[help_buf].filetype), 0)
  end

  if vim.bo[help_buf].buftype ~= "nofile" then
    error("expected ArkHelp buffer to be nofile, got " .. tostring(vim.bo[help_buf].buftype), 0)
  end

  if lines[1] ~= "Arithmetic Mean" then
    error("unexpected ArkHelp title: " .. vim.inspect(lines), 0)
  end

  local function line_index(value)
    for index, line in ipairs(lines) do
      if line == value then
        return index
      end
    end
  end

  local contents_index = line_index("Contents:")
  local usage_index = line_index("Usage:")
  local arguments_index = line_index("Arguments:")
  local usage_fence_index = usage_index and line_index("```r") or nil
  local usage_text_index = line_index("     mean(x, ...)")

  if not contents_index
    or not usage_index
    or not usage_fence_index
    or usage_fence_index <= usage_index
    or not usage_text_index
    or usage_text_index <= usage_fence_index
  then
    error("unexpected ArkHelp usage block: " .. vim.inspect(lines), 0)
  end

  if not arguments_index or arguments_index <= usage_index then
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
