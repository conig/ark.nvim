local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

-- A headless Neovim process cannot stay in Insert mode between input events.
-- Exercise the standalone console in a real PTY and send xterm mouse-wheel
-- sequences, as the terminal containing the managed console does.
local output = vim.fn.system({ "python3", "tests/e2e/nvim_console_mouse_wheel.py" })
if vim.v.shell_error ~= 0 then
  ark_test.fail(output)
end

vim.print(output)
