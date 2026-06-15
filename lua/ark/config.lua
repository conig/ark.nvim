local M = {}

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
      if vim.uv.fs_stat(candidate) then
        return candidate
      end
    elseif vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
end

local root = repo_root()

function M.defaults()
  local lsp_bin = first_executable(compact(
    vim.env.ARK_NVIM_LSP_BIN,
    root .. "/target/debug/ark-lsp",
    root .. "/target/release/ark-lsp",
    "ark-lsp"
  )) or "ark-lsp"

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
    lsp = {
      name = "ark_lsp",
      cmd = { lsp_bin, "--runtime-mode", "detached" },
      file_watch = true,
      root_markers = { ".git", ".Rproj", "DESCRIPTION", "renv.lock" },
      restart_wait_ms = 2000,
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

return M
