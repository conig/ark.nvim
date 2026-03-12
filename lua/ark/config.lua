local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function first_executable(candidates)
  for _, candidate in ipairs(candidates) do
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
  local lsp_bin = first_executable({
    vim.env.ARK_NVIM_LSP_BIN,
    "ark-lsp",
    root .. "/target/debug/ark-lsp",
    root .. "/target/release/ark-lsp",
  }) or "ark-lsp"

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
      launcher = root .. "/scripts/ark-r-launcher.sh",
      pane_percent = 33,
      pane_width_env_keys = {
        "TMUX_CODING_PANE_WIDTH",
        "TMUX_JOIN_WIDTH",
        "GOOTABS_JOIN_WIDTH",
      },
    },
  }
end

return M
