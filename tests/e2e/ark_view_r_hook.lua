vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_view_r_hook")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local fake_nvim = vim.fs.normalize(run_tmpdir .. "/fake-nvim")
local fake_nvim_log = vim.fs.normalize(run_tmpdir .. "/fake-nvim.log")
local fake_console_wrapper = vim.fs.normalize(run_tmpdir .. "/fake-ark-console")
local fake_console_wrapper_log = vim.fs.normalize(run_tmpdir .. "/fake-ark-console.log")
local fallback_log = vim.fs.normalize(run_tmpdir .. "/fallback.log")
local status_file = vim.fs.normalize(run_tmpdir .. "/status.json")
local r_script = vim.fs.normalize(run_tmpdir .. "/ark-view-hook.R")

vim.fn.writefile({
  "#!/usr/bin/env bash",
  "log=" .. vim.fn.shellescape(fake_nvim_log),
  "printf 'CALL\\n' >> \"$log\"",
  "headless=0",
  "for arg in \"$@\"; do [ \"$arg\" = '--headless' ] && headless=1; done",
  "for arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"$log\"; done",
  "if [ \"$headless\" = 1 ]; then",
  "  printf 'ok\\n'",
  "else",
  "  printf '\\033[H\\033[Jok\\033[44B\\n'",
  "fi",
}, fake_nvim)
vim.fn.setfperm(fake_nvim, "rwxr-xr-x")

vim.fn.writefile({
  "#!/usr/bin/env bash",
  "log=" .. vim.fn.shellescape(fake_console_wrapper_log),
  "printf 'WRAPPER\\n' >> \"$log\"",
  "for arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"$log\"; done",
  "printf 'fake ark-console wrapper must not be used for --server --remote-expr\\n' >&2",
  "exit 17",
}, fake_console_wrapper)
vim.fn.setfperm(fake_console_wrapper, "rwxr-xr-x")

vim.fn.writefile({
  vim.json.encode({
    nvim_console_rpc_socket = vim.fs.normalize(run_tmpdir .. "/ark-console.sock"),
  }),
}, status_file)

local function r_string(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. value .. '"'
end

vim.fn.writefile({
  "source(" .. r_string(vim.fs.normalize(vim.fn.getcwd() .. "/packages/arkbridge/R/utils.R")) .. ")",
  "source(" .. r_string(vim.fs.normalize(vim.fn.getcwd() .. "/packages/arkbridge/R/help.R")) .. ")",
  "fallback_log <- " .. r_string(fallback_log),
  "assign('View', function(x, title) {",
  "  expr <- paste(deparse(substitute(x)), collapse = ' ')",
  "  cat('global:', expr, '\\n', file = fallback_log, append = TRUE, sep = '')",
  "  invisible('global-fallback')",
  "}, envir = .GlobalEnv)",
  "utils_ns <- asNamespace('utils')",
  "utils_locked <- bindingIsLocked('View', utils_ns)",
  "if (utils_locked) unlockBinding('View', utils_ns)",
  "assign('View', function(x, title) {",
  "  expr <- paste(deparse(substitute(x)), collapse = ' ')",
  "  cat('utils:', expr, '\\n', file = fallback_log, append = TRUE, sep = '')",
  "  invisible('utils-fallback')",
  "}, envir = utils_ns)",
  "if (utils_locked) lockBinding('View', utils_ns)",
  "Sys.setenv(ARK_NVIM_CONSOLE_NVIM = " .. r_string(fake_console_wrapper) .. ")",
  "ok <- .ark_install_help_hook(list(",
  "  status_file = " .. r_string(status_file) .. ",",
  "  nvim_bin = " .. r_string(fake_nvim),
  "))",
  "stopifnot(isTRUE(ok))",
  "mtcars <- data.frame(mpg = c(21, 22), cyl = c(6, 4))",
  "parent_df <- data.frame(x = 1:2)",
  "View(mtcars)",
  "View(head(mtcars, 1))",
  "utils_view <- get('View', envir = asNamespace('utils'), inherits = FALSE)",
  "utils_view(mtcars)",
  "system2 <- function(...) structure('ok', status = 1L)",
  "request_ok <- .ark_request_neovim_view('iris')",
  "if (!isTRUE(request_ok)) stop('ArkView request should accept ok sentinel even with nonzero status attr')",
  "rm(system2, envir = .GlobalEnv)",
  "writeLines('{\"status\":\"ready\"}', " .. r_string(status_file) .. ")",
  "Sys.setenv(ARK_NVIM_PARENT_SERVER = '/tmp/ark-parent.sock')",
  "Sys.setenv(ARK_NVIM_PARENT_NVIM = " .. r_string(fake_nvim) .. ")",
  "View(parent_df)",
}, r_script)

local output = vim.fn.systemlist({ "Rscript", r_script })
if vim.v.shell_error ~= 0 then
  ark_test.fail("R View hook script failed: " .. table.concat(output, "\n"))
end

if vim.fn.filereadable(fake_console_wrapper_log) == 1 then
  ark_test.fail(
    "ArkView hook used the nvim-console launcher wrapper for --server --remote-expr: "
      .. table.concat(vim.fn.readfile(fake_console_wrapper_log), "\n")
  )
end

local nvim_log = table.concat(vim.fn.readfile(fake_nvim_log), "\n")
if not nvim_log:find("v:lua.__ark_console_rpc_ark_view('mtcars')", 1, true) then
  ark_test.fail("expected View(mtcars) to request ArkView RPC, got " .. nvim_log)
end
if not nvim_log:find("v:lua.__ark_console_rpc_ark_view('head(mtcars, 1)')", 1, true) then
  ark_test.fail("expected View(head(mtcars, 1)) to request ArkView RPC, got " .. nvim_log)
end
if not nvim_log:find("--headless", 1, true) then
  ark_test.fail("expected ArkView RPC to invoke nvim --headless, got " .. nvim_log)
end
if not nvim_log:find("v:lua.__ark_nvim_view_rpc('parent_df')", 1, true) then
  ark_test.fail("expected parent Neovim View RPC fallback, got " .. nvim_log)
end

local _, console_call_count = nvim_log:gsub("__ark_console_rpc_ark_view", "")
local _, parent_call_count = nvim_log:gsub("__ark_nvim_view_rpc", "")
if console_call_count ~= 3 or parent_call_count ~= 1 then
  ark_test.fail("expected three console View RPC calls and one parent View RPC call, got " .. nvim_log)
end

local fallback = ""
if vim.fn.filereadable(fallback_log) == 1 then
  fallback = table.concat(vim.fn.readfile(fallback_log), "\n")
end
if fallback:find("mtcars", 1, true) or fallback:find("parent_df", 1, true) then
  ark_test.fail("successful ArkView RPC should not fall back to original View, got " .. fallback)
end

vim.print({
  ark_view_r_hook = "ok",
})

stop_watchdog()
