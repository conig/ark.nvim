vim.opt.rtp:prepend(vim.fn.getcwd())

local ark = require("ark")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "/tmp/ark_package_install_missing_diagnostics.R")
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "r"

local ns = vim.api.nvim_create_namespace("ark-package-install-missing-test")
vim.diagnostic.set(ns, bufnr, {
  {
    lnum = 0,
    col = 0,
    message = "Package 'zeta' is not installed.",
    severity = vim.diagnostic.severity.WARN,
  },
  {
    lnum = 1,
    col = 0,
    message = "Package 'alpha' is not installed.",
    severity = vim.diagnostic.severity.WARN,
  },
  {
    lnum = 2,
    col = 0,
    message = "Package 'zeta' is not installed.",
    severity = vim.diagnostic.severity.WARN,
  },
  {
    lnum = 3,
    col = 0,
    message = "No symbol named 'zeta' in scope.",
    severity = vim.diagnostic.severity.WARN,
  },
})

local packages = ark.missing_packages(bufnr)
if not vim.deep_equal(packages, { "alpha", "zeta" }) then
  error("unexpected missing package list: " .. vim.inspect(packages), 0)
end
