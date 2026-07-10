vim.cmd("runtime plugin/ark.lua")
assert(vim.fn.exists(":Ark") == 2)
assert(vim.fn.exists(":ArkReport") == 2)

vim.cmd("Ark report")
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(bufnr):find("ark://support%-report"))
local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
assert(text:find("Product state: `static_only`", 1, true), text)
assert(text:find("Configured: no", 1, true), text)
assert(not text:find("auth_token", 1, true), text)

vim.cmd("ArkReport")
assert(vim.api.nvim_buf_get_name(0):find("ark://support%-report"))
