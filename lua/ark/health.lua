local config = require("ark.config")
local console_frontend = require("ark.console_frontend")
local release = require("ark.release")

local M = {}
local active_reporter = nil

local function health_reporter()
  return active_reporter or vim.health or require("health")
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

local function version_at_least(actual, minimum)
  for index = 1, math.max(#actual, #minimum) do
    local lhs = tonumber(actual[index] or 0) or 0
    local rhs = tonumber(minimum[index] or 0) or 0
    if lhs ~= rhs then
      return lhs > rhs
    end
  end
  return true
end

local function writable_location(path)
  local candidate = path
  while type(candidate) == "string" and candidate ~= "" do
    if stat(candidate) then
      return vim.fn.filewritable(candidate) == 2
    end
    local parent = vim.fs.dirname(candidate)
    if parent == candidate then
      break
    end
    candidate = parent
  end
  return false
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  return decoded_ok and type(decoded) == "table" and decoded or nil
end

function M.check()
  local report = health_reporter()
  local ark = package.loaded["ark"]
  local configured = type(ark) == "table" and type(ark.configured_options) == "function"
      and ark.configured_options()
    or nil
  local defaults = configured or config.defaults()
  local backend = defaults.session.backend
  local frontend = console_frontend.normalize(defaults.session.console_frontend)
  local runtime = defaults[backend] or {}
  local launcher = runtime.launcher
  local lsp_bin = defaults.lsp.cmd[1]
  local status_dir = runtime.startup_status_dir
  local bridge_pkg = runtime.session_pkg_path
  local bridge_lib = runtime.session_lib_path
  local r_bin = vim.env.ARK_NVIM_R_BIN or "R"

  report.start("ark.nvim")

  local nvim_version = vim.version()
  if version_at_least(
    { nvim_version.major, nvim_version.minor, nvim_version.patch },
    { 0, 11, 3 }
  ) then
    report.ok(string.format(
      "Neovim %d.%d.%d satisfies the supported minimum 0.11.3",
      nvim_version.major,
      nvim_version.minor,
      nvim_version.patch
    ))
  else
    report.error("Neovim 0.11.3 or newer is required. Recovery: upgrade Neovim before loading Ark.")
  end

  report.ok("Configured session backend: " .. backend)
  report.ok("Configured console frontend: " .. frontend)

  if vim.fn.has("linux") == 1 and defaults.lsp.file_watch ~= false then
    if executable("inotifywait") then
      report.ok("`inotifywait` is available for efficient Linux workspace file watching")
    else
      report.warn(
        "`inotifywait` is unavailable; Neovim's fallback file watcher can block startup in large workspaces. "
          .. "Recovery: install inotify-tools and restart Neovim. If external file discovery is not needed, "
          .. "set lsp.file_watch = false."
      )
    end
  end

  local release_status = release.status()
  if release_status.product_version then
    report.ok("Ark product version: " .. release_status.product_version)
  else
    report.error("Ark release manifest is invalid: " .. tostring(release_status.manifest_error))
  end
  local manifest = release.manifest()
  local compatibility = manifest and manifest.compatibility or {}
  if compatibility.bridge_schema == "v1" and compatibility.plugin_api == 1 and compatibility.lsp_api == 1 then
    report.ok("Component compatibility contract: plugin API 1, LSP API 1, bridge schema v1")
  else
    report.error("Release compatibility metadata is unsupported. Recovery: reinstall the matching Ark release.")
  end
  local target, target_err = release.release_target()
  if target then
    report.ok("Published release target is available: " .. tostring(target.rust_target))
    local ok_glibc, glibc_lines = systemlist({ "getconf", "GNU_LIBC_VERSION" })
    local glibc_major, glibc_minor
    if ok_glibc then
      glibc_major, glibc_minor = (glibc_lines[1] or ""):match("glibc%s+(%d+)%.(%d+)")
    end
    if glibc_major then
      local minimum_major, minimum_minor = tostring(target.minimum_glibc):match("(%d+)%.(%d+)")
      if version_at_least({ glibc_major, glibc_minor }, { minimum_major, minimum_minor }) then
        report.ok("glibc satisfies the release minimum " .. tostring(target.minimum_glibc))
      else
        report.error("glibc is older than " .. tostring(target.minimum_glibc) .. ". Recovery: use a supported system or the source-build fallback.")
      end
    end
  else
    report.error(tostring(target_err) .. ". Recovery: use a supported release platform or the documented source-build fallback.")
  end

  if backend == "tmux" then
    ok_or_error(
      report,
      executable("tmux"),
      "`tmux` is available",
      "`tmux` is required for the configured session backend. Recovery: install tmux or set session.backend = 'terminal'."
    )

    if type(vim.env.TMUX) == "string" and vim.env.TMUX ~= "" then
      report.ok("Neovim is running inside tmux")
    else
      report.warn("Neovim is not running inside tmux; the configured tmux backend will not attach. Recovery: start Neovim inside tmux or select the terminal backend.")
    end
  elseif backend == "terminal" then
    if vim.fn.exists("*termopen") == 1 then
      report.ok("Neovim terminal support is available")
    else
      report.error("The configured terminal backend requires Neovim terminal support. Recovery: upgrade or rebuild Neovim with terminal support.")
    end
  else
    report.error("Configured session backend is not supported by this ark.nvim build: " .. backend .. ". Recovery: use 'tmux' or 'terminal'.")
  end

  if executable(r_bin) then
    local ok_version, version_lines = systemlist({ r_bin, "--version" })
    local version = ok_version and version_lines[1] or nil
    if type(version) == "string" and version ~= "" then
      local major, minor = version:match("R version%s+(%d+)%.(%d+)")
      if major and version_at_least({ major, minor }, { 4, 2 }) then
        report.ok("R is available and supported: " .. version)
      else
        report.error("R 4.2 or newer is required; found: " .. version .. ". Recovery: upgrade R.")
      end
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
      report.error("R package `jsonlite` is required. Recovery: run install.packages('jsonlite') in R.")
    end
  else
    report.error("R executable is unavailable: " .. r_bin .. ". Recovery: install R 4.2+ or set ARK_NVIM_R_BIN.")
  end

  ok_or_error(
    report,
    executable(launcher) and file_exists(launcher),
    "Launcher is executable: " .. launcher,
    "Launcher is missing or not executable: " .. launcher .. ". Recovery: reinstall Ark or correct ARK_NVIM_LAUNCHER."
  )

  if frontend == "nvim-console" then
    local nvim_console_bin = console_frontend.nvim_console_bin(runtime)
    if executable(nvim_console_bin) then
      report.ok("Neovim console frontend executable is available: " .. nvim_console_bin)
    else
      report.error("Neovim console frontend is configured but executable is unavailable: " .. nvim_console_bin .. ". Recovery: correct session.console_frontend or its nvim_console.bin.")
    end
  elseif frontend ~= "raw" then
    report.error("Configured console frontend is not supported by this ark.nvim build: " .. frontend .. ". Recovery: use 'raw' or 'nvim-console'.")
  end

  if file_exists(lsp_bin) and executable(lsp_bin) then
    report.ok("Detached `ark-lsp` binary is executable: " .. lsp_bin)
  elseif executable(lsp_bin) then
    report.ok("Detached `ark-lsp` binary is discoverable on PATH: " .. lsp_bin)
  else
    report.warn("Detached `ark-lsp` binary is not discoverable. Run `:Ark install`, set `ARK_NVIM_LSP_BIN`, or use the documented source-build fallback.")
  end


  if release_status.installed_metadata then
    if release_status.installed_metadata.product_version == release_status.product_version then
      report.ok("Installed ark-lsp matches the plugin product version")
    else
      report.error(string.format(
        "Installed ark-lsp version %s is incompatible with plugin version %s; run `:Ark install` or `:Ark rollback`",
        tostring(release_status.installed_metadata.product_version),
        tostring(release_status.product_version)
      ))
    end
    if release_status.installed_metadata.profile == "release" then
      report.ok("Installed ark-lsp is an optimized release build")
    else
      report.error("Installed ark-lsp is not an optimized release build. Recovery: run :Ark install.")
    end
  elseif release_status.installed_binary then
    report.error("Installed ark-lsp version metadata is unreadable: " .. tostring(release_status.installed_metadata_error) .. ". Recovery: run :Ark install or :Ark rollback.")
  else
    report.info("No Ark-managed release is installed under: " .. release_status.install_root)
  end

  if writable_location(release_status.install_root) then
    report.ok("Ark install location is writable: " .. release_status.install_root)
  else
    report.error("Ark install location is not writable: " .. release_status.install_root .. ". Recovery: fix its ownership or set ARK_NVIM_INSTALL_ROOT.")
  end

  ok_or_error(
    report,
    dir_exists(bridge_pkg),
    "Bridge package source is present: " .. bridge_pkg,
    "Bridge package source is missing: " .. bridge_pkg .. ". Recovery: reinstall the Ark plugin checkout."
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
      local incompatible = 0
      for _, path in ipairs(files) do
        local payload = read_json(path)
        if payload and payload.status == "ready"
          and (payload.product_version ~= release_status.product_version or payload.bridge_schema ~= compatibility.bridge_schema)
        then
          incompatible = incompatible + 1
        end
      end
      if incompatible > 0 then
        report.error(string.format(
          "%d ready bridge status file(s) are incompatible. Recovery: run :Ark pane restart after :Ark install.",
          incompatible
        ))
      end
    else
      report.info("Status directory exists but has no current session files: " .. status_dir)
    end
  else
    report.info("Status directory will be created on first launcher start: " .. status_dir)
  end

  if writable_location(status_dir) then
    report.ok("Ark state location is writable: " .. status_dir)
  else
    report.error("Ark state location is not writable: " .. status_dir .. ". Recovery: fix its ownership or set ARK_STATUS_DIR.")
  end
end

function M.collect()
  local entries = {}
  active_reporter = {
    start = function(message) entries[#entries + 1] = { kind = "start", message = message } end,
    ok = function(message) entries[#entries + 1] = { kind = "ok", message = message } end,
    warn = function(message) entries[#entries + 1] = { kind = "warn", message = message } end,
    error = function(message) entries[#entries + 1] = { kind = "error", message = message } end,
    info = function(message) entries[#entries + 1] = { kind = "info", message = message } end,
  }
  local ok, err = pcall(M.check)
  active_reporter = nil
  if not ok then
    entries[#entries + 1] = { kind = "error", message = "Health collection failed: " .. tostring(err) }
  end
  return entries
end

return M
