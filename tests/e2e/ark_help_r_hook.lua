vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_help_r_hook")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local fake_nvim = vim.fs.normalize(run_tmpdir .. "/fake-nvim")
local fake_nvim_log = vim.fs.normalize(run_tmpdir .. "/fake-nvim.log")
local fake_console_wrapper = vim.fs.normalize(run_tmpdir .. "/fake-ark-console")
local fake_console_wrapper_log = vim.fs.normalize(run_tmpdir .. "/fake-ark-console.log")
local fallback_log = vim.fs.normalize(run_tmpdir .. "/fallback.log")
local status_file = vim.fs.normalize(run_tmpdir .. "/status.json")
local r_script = vim.fs.normalize(run_tmpdir .. "/ark-help-hook.R")

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
  "assign('?', function(e1, e2) {",
  "  expr <- paste(deparse(substitute(e1)), collapse = ' ')",
  "  if (!missing(e2)) expr <- paste(expr, paste(deparse(substitute(e2)), collapse = ' '), sep = ' ? ')",
  "  cat(expr, '\\n', file = fallback_log, append = TRUE)",
  "  invisible('fallback')",
  "}, envir = .GlobalEnv)",
  "Sys.setenv(ARK_NVIM_CONSOLE_NVIM = " .. r_string(fake_console_wrapper) .. ")",
  "ok <- .ark_install_help_hook(list(",
  "  status_file = " .. r_string(status_file) .. ",",
  "  nvim_bin = " .. r_string(fake_nvim),
  "))",
  "stopifnot(isTRUE(ok))",
  "eval(parse(text = '?lm'), envir = .GlobalEnv)",
  "eval(parse(text = '?\"+\"'), envir = .GlobalEnv)",
  "# Interactive R resolves top-level ? through utils::`?`, whose body",
  "# calls help() inside the utils namespace instead of .GlobalEnv$`?`.",
  "utils_question <- get('?', envir = asNamespace('utils'), inherits = FALSE)",
  "namespace_help_output <- capture.output(utils_question(lm))",
  "if (any(grepl('R Documentation|Fitting Linear Models', namespace_help_output))) {",
  "  stop('utils namespace ? path printed base help instead of routing to ArkHelp')",
  "}",
  "# If interactive R still materializes a normal help object, the S3 print",
  "# method is the final boundary that dumps overstrike text into the console.",
  "base_help <- .ark_original_help_function()('lm', help_type = 'text')",
  "capture.output(print(base_help))",
  "system2 <- function(...) structure('ok', status = 1L)",
  "request_ok <- .ark_request_neovim_help('median')",
  "if (!isTRUE(request_ok)) stop('ArkHelp request should accept ok sentinel even with nonzero status attr')",
  "eval(parse(text = '?median'), envir = .GlobalEnv)",
  "rm(system2, envir = .GlobalEnv)",
  "writeLines('{\"status\":\"ready\"}', " .. r_string(status_file) .. ")",
  "Sys.setenv(ARK_NVIM_PARENT_SERVER = '/tmp/ark-parent.sock')",
  "Sys.setenv(ARK_NVIM_PARENT_NVIM = " .. r_string(fake_nvim) .. ")",
  "eval(parse(text = '?mean'), envir = .GlobalEnv)",
  "eval(parse(text = '??lm'), envir = .GlobalEnv)",
  "eval(parse(text = 'utils?help'), envir = .GlobalEnv)",
}, r_script)

local output = vim.fn.systemlist({ "Rscript", r_script })
if vim.v.shell_error ~= 0 then
  ark_test.fail("R help hook script failed: " .. table.concat(output, "\n"))
end

if vim.fn.filereadable(fake_console_wrapper_log) == 1 then
  ark_test.fail(
    "ArkHelp hook used the nvim-console launcher wrapper for --server --remote-expr: "
      .. table.concat(vim.fn.readfile(fake_console_wrapper_log), "\n")
  )
end

local nvim_log = table.concat(vim.fn.readfile(fake_nvim_log), "\n")
if not nvim_log:find("v:lua.__ark_console_rpc_ark_help('lm')", 1, true) then
  ark_test.fail("expected ?lm to request ArkHelp RPC, got " .. nvim_log)
end
if not nvim_log:find("--headless", 1, true) then
  ark_test.fail("expected ArkHelp RPC to invoke nvim --headless, got " .. nvim_log)
end
local _, lm_call_count = nvim_log:gsub("__ark_console_rpc_ark_help%('lm'%)", "")
local _, stats_lm_call_count = nvim_log:gsub("__ark_console_rpc_ark_help%('stats::lm'%)", "")
if lm_call_count ~= 2 or stats_lm_call_count ~= 1 then
  ark_test.fail("expected global, utils namespace, and help-object print ?lm paths to request ArkHelp RPC, got " .. nvim_log)
end
if not nvim_log:find("v:lua.__ark_console_rpc_ark_help('+')", 1, true) then
  ark_test.fail("expected quoted operator help to request ArkHelp RPC, got " .. nvim_log)
end
if not nvim_log:find("v:lua.__ark_nvim_help_rpc('mean')", 1, true) then
  ark_test.fail("expected parent Neovim help RPC fallback, got " .. nvim_log)
end

local _, remote_call_count = nvim_log:gsub("__ark_console_rpc_ark_help", "")
local _, parent_call_count = nvim_log:gsub("__ark_nvim_help_rpc", "")
if remote_call_count ~= 4 or parent_call_count ~= 1 then
  ark_test.fail("expected only supported help forms to route to ArkHelp, got " .. nvim_log)
end

local fallback = table.concat(vim.fn.readfile(fallback_log), "\n")
for line in (fallback .. "\n"):gmatch("(.-)\n") do
  if line == "lm" or line == '"+"' or line == "median" then
    ark_test.fail("successful ArkHelp RPC should not fall back to original help operator, got " .. fallback)
  end
end
if not fallback:find("`%?`%(lm%)") then
  ark_test.fail("expected ??lm to fall back to the original help operator, got " .. fallback)
end
if not fallback:find("utils ? help", 1, true) then
  ark_test.fail("expected binary typed help to fall back to the original help operator, got " .. fallback)
end

vim.print({
  ark_help_r_hook = "ok",
})

stop_watchdog()
