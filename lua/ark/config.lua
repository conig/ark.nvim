local M = {}

local function compact(...)
  local values = { ... }
  local out = {}

  for _, value in ipairs(values) do
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
    "ark-lsp",
    root .. "/target/debug/ark-lsp",
    root .. "/target/release/ark-lsp"
  )) or "ark-lsp"

  local launcher = first_executable(compact(
    vim.env.ARK_NVIM_LAUNCHER,
    "~/repos/rscope.nvim/nvim/scripts/rscope_r_launcher.sh",
    root .. "/scripts/ark-r-launcher.sh"
  )) or (root .. "/scripts/ark-r-launcher.sh")

  local session_kind = vim.env.ARK_NVIM_SESSION_KIND
  if not session_kind and launcher:match("rscope_r_launcher%.sh$") then
    session_kind = "rscope"
  end

  return {
    auto_start_pane = true,
    auto_start_lsp = true,
    configure_slime = true,
    filetypes = { "r", "rmd", "qmd", "quarto" },
    lsp = {
      name = "ark_lsp",
      cmd = { lsp_bin, "--runtime-mode", "detached" },
      root_markers = { ".git", ".Rproj", "DESCRIPTION", "renv.lock" },
    },
    tmux = {
      launcher = launcher,
      pane_percent = 33,
      pane_width_env_keys = {
        "TMUX_CODING_PANE_WIDTH",
        "TMUX_JOIN_WIDTH",
        "GOOTABS_JOIN_WIDTH",
      },
      session_kind = session_kind,
      startup_status_dir = vim.env.RSCOPE_STATUS_DIR or ((vim.fn.stdpath("state") or "/tmp") .. "/rscope-status"),
      bridge_wait_ms = 5000,
      session_timeout_ms = 1000,
    },
  }
end

return M
