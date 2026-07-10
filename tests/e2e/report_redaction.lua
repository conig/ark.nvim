local report = require("ark.report")

local secret = string.rep("a", 64)
local home = vim.uv.os_homedir()
local lines = report.generate({
  status = {
    product_state = "live_degraded",
    backend = "tmux",
    startup = { phase = "live_degraded" },
    lsp_status = { available = true, runtimeMode = "detached" },
  },
  release_status = {
    product_version = "0.1.0-test",
    installed_metadata = { product_version = "0.1.0-test", profile = "release" },
  },
  health_checks = {
    { kind = "error", message = "auth_token=" .. secret .. " under " .. home .. "/private" },
    { kind = "info", message = "Bearer do-not-share session_cookie=also-private api_token=private-too" },
  },
})
local text = table.concat(lines, "\n")
assert(not text:find(secret, 1, true), text)
assert(not text:find("do-not-share", 1, true), text)
assert(not text:find("also-private", 1, true), text)
assert(not text:find("private-too", 1, true), text)
assert(not text:find(home, 1, true), text)
assert(text:find("<REDACTED>", 1, true), text)
assert(text:find("<HOME>", 1, true), text)
assert(not text:find("source buffer", 1, true), text)

local bufnr = report.open({
  status = { configured = false, product_state = "static_only" },
  release_status = { product_version = "test" },
  health_checks = {},
})
assert(vim.api.nvim_buf_is_valid(bufnr))
assert(vim.bo[bufnr].buftype == "nofile")
assert(vim.bo[bufnr].filetype == "markdown")
assert(vim.api.nvim_buf_get_name(bufnr):find("ark://support%-report"))
