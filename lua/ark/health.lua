local config = require("ark.config")

local M = {}

local function health_reporter()
  return vim.health or require("health")
end

local function stat(path)
  local uv = vim.uv or vim.loop
  if not uv or type(uv.fs_stat) ~= "function" then
    return nil
  end
  return uv.fs_stat(path)
end

local function file_exists(path)
  local info = stat(path)
  return type(info) == "table" and info.type == "file"
end

local function dir_exists(path)
  local info = stat(path)
  return type(info) == "table" and info.type == "directory"
end

local function executable(path)
  return type(path) == "string" and path ~= "" and vim.fn.executable(path) == 1
end

local function ok_or_error(report, ok, success, failure)
  if ok then
    report.ok(success)
  else
    report.error(failure)
  end
end

local function systemlist(cmd)
  local output = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, output
end

function M.check()
  local report = health_reporter()
  local defaults = config.defaults()
  local launcher = defaults.tmux.launcher
  local lsp_bin = defaults.lsp.cmd[1]
  local status_dir = defaults.tmux.startup_status_dir
  local bridge_pkg = defaults.tmux.session_pkg_path
  local bridge_lib = defaults.tmux.session_lib_path
  local r_bin = vim.env.ARK_NVIM_R_BIN or "R"

  report.start("ark.nvim")

  ok_or_error(
    report,
    executable("tmux"),
    "`tmux` is available",
    "`tmux` is required for managed pane mode"
  )

  if type(vim.env.TMUX) == "string" and vim.env.TMUX ~= "" then
    report.ok("Neovim is running inside tmux")
  else
    report.warn("Neovim is not running inside tmux; managed pane mode will not attach")
  end

  if executable(r_bin) then
    local ok_version, version_lines = systemlist({ r_bin, "--version" })
    local version = ok_version and version_lines[1] or nil
    if type(version) == "string" and version ~= "" then
      report.ok("R is available: " .. version)
    else
      report.ok("R is available: " .. r_bin)
    end

    local ok_jsonlite, jsonlite_lines = systemlist({
      r_bin,
      "--slave",
      "-e",
      'cat(if (requireNamespace("jsonlite", quietly = TRUE)) "yes" else "no")',
    })
    if ok_jsonlite and jsonlite_lines[1] == "yes" then
      report.ok("R package `jsonlite` is installed")
    else
      report.error("R package `jsonlite` is required")
    end
  else
    report.error("R executable is unavailable: " .. r_bin)
  end

  ok_or_error(
    report,
    executable(launcher) and file_exists(launcher),
    "Launcher is executable: " .. launcher,
    "Launcher is missing or not executable: " .. launcher
  )

  if file_exists(lsp_bin) and executable(lsp_bin) then
    report.ok("Detached `ark-lsp` binary is executable: " .. lsp_bin)
  elseif executable(lsp_bin) then
    report.ok("Detached `ark-lsp` binary is discoverable on PATH: " .. lsp_bin)
  else
    report.warn("Detached `ark-lsp` binary is not discoverable. Build with `cargo build -p ark --bin ark-lsp` or set `ARK_NVIM_LSP_BIN`.")
  end

  ok_or_error(
    report,
    dir_exists(bridge_pkg),
    "Bridge package source is present: " .. bridge_pkg,
    "Bridge package source is missing: " .. bridge_pkg
  )

  if dir_exists(bridge_lib) and dir_exists(bridge_lib .. "/arkbridge") then
    report.ok("Pane-side `arkbridge` runtime is installed: " .. bridge_lib)
  else
    report.info("Pane-side `arkbridge` runtime will be installed into: " .. bridge_lib)
  end

  if dir_exists(status_dir) then
    local files = vim.fn.glob(status_dir .. "/*.json", false, true)
    if type(files) == "table" and #files > 0 then
      report.ok(string.format("Status directory is present with %d status file(s): %s", #files, status_dir))
    else
      report.info("Status directory exists but has no current session files: " .. status_dir)
    end
  else
    report.info("Status directory will be created on first launcher start: " .. status_dir)
  end
end

return M
