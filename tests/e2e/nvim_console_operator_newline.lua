vim.opt.rtp:prepend(vim.fn.getcwd())

local console = require("ark.console")

local function find_upvalue(fn, name)
  for index = 1, math.huge do
    local key, value = debug.getupvalue(fn, index)
    if key == nil then
      return nil
    end
    if key == name then
      return value
    end
  end
end

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].modifiable = true
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#> old output", "mtcars" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })

local state = _G.__ark_nvim_console_state
state.buffers[bufnr] = {
  input_start = 1,
  output_pending = "",
  prompt_state = "top-level",
}

local ok, err = console.append_pipe_newline(bufnr)
if not ok then
  error("append_pipe_newline failed: " .. tostring(err), 0)
end

local lines = vim.api.nvim_buf_get_lines(bufnr, 1, -1, false)
assert(
  vim.deep_equal(lines, { "mtcars |> ", "" }),
  "pipe mapping should append '|>' and open a line: " .. vim.inspect(lines)
)

vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, { "ggplot(mtcars, aes(mpg, wt))" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

ok, err = console.append_plus_newline(bufnr)
if not ok then
  error("append_plus_newline failed: " .. tostring(err), 0)
end

lines = vim.api.nvim_buf_get_lines(bufnr, 1, -1, false)
assert(
  vim.deep_equal(lines, { "ggplot(mtcars, aes(mpg, wt)) + ", "" }),
  "plus mapping should focus input, append '+', and open a line: " .. vim.inspect(lines)
)

local enter_insert_from_normal_i = find_upvalue(console.start, "enter_insert_from_normal_i")
assert(type(enter_insert_from_normal_i) == "function", "missing console normal i helper")

enter_insert_from_normal_i(bufnr)
local cursor = vim.api.nvim_win_get_cursor(0)
assert(
  vim.deep_equal(cursor, { 3, 0 }),
  "normal i should stay on a lower active input line, got " .. vim.inspect(cursor)
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
enter_insert_from_normal_i(bufnr)
cursor = vim.api.nvim_win_get_cursor(0)
assert(
  vim.deep_equal(cursor, { 2, 0 }),
  "normal i above the prompt should teleport to the active input start, got " .. vim.inspect(cursor)
)

print("nvim console operator newline ok")
vim.cmd("qa!")
