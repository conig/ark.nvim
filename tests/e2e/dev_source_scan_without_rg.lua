-- Source identity must not depend on ripgrep, Git, or development mode.
local executable = vim.fn.executable
vim.fn.executable = function(command)
  if command == "rg" or command == "git" then return 0 end
  return executable(command)
end
local completed = false
require("ark.identity").snapshot(vim.fn.getcwd() .. "/target/debug/ark-lsp", "lsp", function(snapshot, err)
  assert(snapshot and not err, tostring(err))
  completed = true
end)
assert(vim.wait(10000, function() return completed end))
