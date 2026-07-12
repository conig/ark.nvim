local M = {}

local OPTIONAL_KEYS = {
  ["help.popup.nvim.init"] = true,
  ["tmux.nvim_console.init"] = true,
  ["terminal.nvim_console.init"] = true,
}

local ENUMS = {
  ["session.backend"] = { tmux = true, terminal = true },
  ["session.console_frontend"] = { raw = true, launcher = true, ["nvim-console"] = true },
  ["help.display"] = {
    auto = true, float = true, nvim = true, nvim_float = true,
    popup = true, tmux = true, tmux_popup = true,
  },
  ["view.display"] = {
    auto = true, tab = true, nvim = true, nvim_tab = true,
    popup = true, tmux = true, tmux_popup = true,
  },
  ["tmux.pane_layout"] = {
    auto = true, side_by_side = true, horizontal = true, landscape = true,
    stacked = true, vertical = true, portrait = true,
  },
  ["terminal.split_direction"] = {
    horizontal = true, split = true, below = true,
    vertical = true, vsplit = true, right = true,
  },
  ["terminal.split_position"] = {
    botright = true, belowright = true, topleft = true, aboveleft = true,
  },
}

local release = require("ark.release")

local function compact(...)
  local out = {}

  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      table.insert(out, value)
    end
  end

  return out
end

local function expand_candidate(candidate)
  if type(candidate) ~= "string" or candidate == "" then
    return nil
  end

  return vim.fn.expand(candidate)
end

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function first_executable(candidates)
  for _, raw_candidate in ipairs(candidates) do
    local candidate = expand_candidate(raw_candidate)
    if candidate:find("/") then
      if vim.uv.fs_stat(candidate) and vim.fn.executable(candidate) == 1 then
        return candidate
      end
    elseif vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
end

local root = repo_root()

function M.defaults()
  local development_mode = vim.env.ARK_NVIM_DEV_MODE == "1"
  local installed_lsp = release.installed_binary()
  local lsp_bin
  if development_mode then
    lsp_bin = first_executable(compact(
      vim.env.ARK_NVIM_LSP_BIN,
      root .. "/target/debug/ark-lsp",
      root .. "/target/release/ark-lsp",
      installed_lsp,
      "ark-lsp"
    ))
  else
    lsp_bin = first_executable(compact(
      vim.env.ARK_NVIM_LSP_BIN,
      installed_lsp,
      "ark-lsp",
      root .. "/target/release/ark-lsp"
    ))
  end
  lsp_bin = lsp_bin or "ark-lsp"

  local launcher = first_executable(compact(
    vim.env.ARK_NVIM_LAUNCHER,
    root .. "/scripts/ark-r-launcher.sh"
  )) or (root .. "/scripts/ark-r-launcher.sh")
  local nvim_console_bin = first_executable(compact(
    vim.env.ARK_NVIM_CONSOLE_BIN,
    root .. "/scripts/ark-console",
    vim.env.ARK_NVIM_CONSOLE_NVIM,
    vim.v.progpath,
    "nvim"
  )) or "nvim"
  local session_lib_path = expand_candidate(vim.env.ARK_NVIM_SESSION_LIB)
    or (vim.fn.stdpath("data") .. "/ark/r-lib")

  local session_backend = vim.env.ARK_NVIM_SESSION_BACKEND or "tmux"
  local session_kind = vim.env.ARK_NVIM_SESSION_KIND or "ark"
  local console_frontend = vim.env.ARK_NVIM_CONSOLE_FRONTEND or "raw"
  local nvim_console = {
    bin = nvim_console_bin,
    command = vim.env.ARK_NVIM_CONSOLE_COMMAND or "Ark console",
    add_repo_to_rtp = vim.env.ARK_NVIM_CONSOLE_ADD_REPO_RTP ~= "0",
  }

  return {
    development_mode = development_mode,
    auto_start_pane = true,
    auto_start_lsp = true,
    async_startup = false,
    configure_slime = true,
    filetypes = { "r", "rmd", "qmd", "quarto" },
    keymaps = {
      enabled = false,
      prefix = "<leader>r",
      target_prefix = "<leader>t",
      snippets = "<leader>as",
    },
    help = {
      display = vim.env.ARK_NVIM_HELP_DISPLAY or "auto",
      popup = {
        width = vim.env.ARK_NVIM_HELP_POPUP_WIDTH or "auto",
        height = vim.env.ARK_NVIM_HELP_POPUP_HEIGHT or "80%",
        viewer = vim.env.ARK_NVIM_HELP_POPUP_VIEWER or "nvim",
        pager = {
          bin = first_executable(compact(vim.env.ARK_NVIM_HELP_POPUP_PAGER, "less")) or "less",
        },
        nvim = {
          bin = first_executable(compact(
            vim.env.ARK_NVIM_HELP_POPUP_NVIM,
            vim.v.progpath,
            "nvim"
          )) or "nvim",
          init = expand_candidate(vim.env.ARK_NVIM_HELP_POPUP_INIT),
        },
      },
    },
    view = {
      display = vim.env.ARK_NVIM_VIEW_DISPLAY or "auto",
      popup = {
        width = vim.env.ARK_NVIM_VIEW_POPUP_WIDTH or "90%",
        height = vim.env.ARK_NVIM_VIEW_POPUP_HEIGHT or "90%",
        nvim = {
          bin = first_executable(compact(
            vim.env.ARK_NVIM_VIEW_POPUP_NVIM,
            vim.v.progpath,
            "nvim"
          )) or "nvim",
        },
      },
    },
    lsp = {
      name = "ark_lsp",
      cmd = { lsp_bin, "--runtime-mode", "detached" },
      file_watch = true,
      root_markers = { ".git", ".Rproj", "DESCRIPTION", "renv.lock" },
      restart_wait_ms = 2000,
      crash_recovery = {
        enabled = true,
        max_restarts = 3,
        window_ms = 30000,
        base_delay_ms = 250,
        max_delay_ms = 2000,
      },
    },
    session = {
      backend = session_backend,
      kind = session_kind,
      console_frontend = console_frontend,
    },
    tmux = {
      launcher = launcher,
      console_frontend = console_frontend,
      nvim_console = nvim_console,
      lsp_bin = lsp_bin,
      pane_layout = "auto",
      stacked_max_width = 100,
      pane_percent = 33,
      stacked_pane_percent = 33,
      pane_width_env_keys = {
        "TMUX_CODING_PANE_WIDTH",
        "TMUX_JOIN_WIDTH",
        "GOOTABS_JOIN_WIDTH",
      },
      session_kind = session_kind,
      startup_status_dir = vim.env.ARK_STATUS_DIR or ((vim.fn.stdpath("state") or "/tmp") .. "/ark-status"),
      session_pkg_path = root .. "/packages/arkbridge",
      session_lib_path = session_lib_path,
      bridge_wait_ms = 5000,
      session_timeout_ms = 1000,
    },
    terminal = {
      launcher = launcher,
      console_frontend = console_frontend,
      nvim_console = nvim_console,
      lsp_bin = lsp_bin,
      split_direction = vim.env.ARK_NVIM_TERMINAL_SPLIT_DIRECTION or "horizontal",
      split_position = vim.env.ARK_NVIM_TERMINAL_SPLIT_POSITION or "botright",
      split_size = tonumber(vim.env.ARK_NVIM_TERMINAL_SPLIT_SIZE or "15") or 15,
      session_kind = session_kind,
      startup_status_dir = vim.env.ARK_STATUS_DIR or ((vim.fn.stdpath("state") or "/tmp") .. "/ark-status"),
      session_pkg_path = root .. "/packages/arkbridge",
      session_lib_path = session_lib_path,
      bridge_wait_ms = 5000,
      session_timeout_ms = 1000,
    },
  }
end

local function is_list(value)
  return type(value) == "table" and vim.islist(value)
end

local function path_join(prefix, key)
  if prefix == "" then
    return tostring(key)
  end
  return prefix .. "." .. tostring(key)
end

local function validate_shape(value, default, path, errors)
  if path == "keymaps" and type(value) == "boolean" then
    return
  end

  if type(value) ~= type(default) then
    errors[#errors + 1] = string.format(
      "config.%s must be %s, got %s",
      path,
      type(default),
      type(value)
    )
    return
  end

  if type(value) ~= "table" then
    return
  end

  if is_list(default) then
    if not is_list(value) then
      errors[#errors + 1] = "config." .. path .. " must be a list"
      return
    end
    for index, item in ipairs(value) do
      if #default > 0 and type(item) ~= type(default[1]) then
        errors[#errors + 1] = string.format(
          "config.%s[%d] must be %s, got %s",
          path,
          index,
          type(default[1]),
          type(item)
        )
      end
    end
    return
  end

  for key, nested in pairs(value) do
    local nested_path = path_join(path, key)
    local nested_default = default[key]
    if nested_default == nil and not OPTIONAL_KEYS[nested_path] then
      errors[#errors + 1] = "unknown config key: config." .. nested_path
    elseif nested_default ~= nil then
      validate_shape(nested, nested_default, nested_path, errors)
    end
  end
end

function M.validate(opts)
  if opts == nil then
    return true, {}
  end
  if type(opts) ~= "table" then
    return false, { "config must be a table, got " .. type(opts) }
  end

  local errors = {}
  validate_shape(opts, M.defaults(), "", errors)
  for path, choices in pairs(ENUMS) do
    local value = opts
    for part in path:gmatch("[^.]+") do
      value = type(value) == "table" and value[part] or nil
    end
    if value ~= nil then
      local normalized = type(value) == "string" and value:lower():gsub("-", "_") or value
      if not choices[value] and not choices[normalized] then
        local accepted = vim.tbl_keys(choices)
        table.sort(accepted)
        errors[#errors + 1] = string.format(
          "config.%s has unsupported value %q; expected one of: %s",
          path,
          tostring(value),
          table.concat(accepted, ", ")
        )
      end
    end
  end

  local split_size = opts.terminal and opts.terminal.split_size or nil
  if split_size ~= nil and (type(split_size) ~= "number" or split_size < 1) then
    errors[#errors + 1] = "config.terminal.split_size must be a positive number"
  end

  local crash_recovery = opts.lsp and opts.lsp.crash_recovery or nil
  for _, key in ipairs({ "max_restarts", "window_ms", "base_delay_ms", "max_delay_ms" }) do
    local value = crash_recovery and crash_recovery[key] or nil
    if type(value) == "number" and (value < 1 or value % 1 ~= 0) then
      errors[#errors + 1] = "config.lsp.crash_recovery." .. key .. " must be a positive integer"
    end
  end

  return #errors == 0, errors
end

function M.assert_valid(opts)
  local ok, errors = M.validate(opts)
  if not ok then
    error(require("ark.errors").format("E_CONFIG", table.concat(errors, "; ")), 0)
  end
  return opts
end

return M
