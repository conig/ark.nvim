local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function shellescape(value)
  return vim.fn.shellescape(tostring(value or ""))
end

local function vim_string(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function normalize(value)
  if value == nil or value == "" or value == "raw" or value == "launcher" then
    return "raw"
  end
  return value
end

local function nvim_console_config(config)
  local nested = type(config.nvim_console) == "table" and config.nvim_console or {}
  return {
    bin = nested.bin or config.nvim_console_bin or vim.v.progpath or "nvim",
    command = nested.command or "Ark console",
    add_repo_to_rtp = nested.add_repo_to_rtp ~= false,
    init = nested.init or config.nvim_console_init or vim.env.ARK_NVIM_CONSOLE_INIT or (repo_root() .. "/scripts/ark-console-init.lua"),
  }
end

function M.normalize(value)
  return normalize(value)
end

function M.validate(value)
  local frontend = normalize(value)
  if frontend == "raw" or frontend == "nvim-console" then
    return frontend, nil
  end

  return nil, "unsupported ark.nvim console frontend: " .. tostring(value)
end

function M.argv(config, backend, session_id)
  config = config or {}
  local frontend, err = M.validate(config.console_frontend)
  if not frontend then
    return nil, err
  end

  if frontend == "raw" then
    return { config.launcher }, nil
  end

  if frontend == "nvim-console" then
    local nvim_console = nvim_console_config(config)
    local theme_file
    local ok_theme, theme = pcall(require, "ark.theme")
    if ok_theme and type(theme) == "table" and type(theme.prepare_handoff) == "function" then
      theme_file = theme.prepare_handoff()
    end

    local argv = {
      nvim_console.bin,
      "-n",
      "--cmd",
      "let g:ark_console_standalone = v:true",
      "--cmd",
      "let g:ark_console_terminal_ui = v:true",
    }
    if type(theme_file) == "string" and theme_file ~= "" then
      vim.list_extend(argv, {
        "--cmd",
        "let $ARK_NVIM_REPL_THEME_FILE = " .. vim_string(theme_file),
      })
    end
    vim.list_extend(argv, {
      "-u",
      nvim_console.init,
    })
    if nvim_console.add_repo_to_rtp then
      vim.list_extend(argv, {
        "-c",
        "set rtp^=" .. repo_root(),
        "-c",
        "if exists(':Ark') != 2 | runtime plugin/ark.lua | endif",
      })
    end
    vim.list_extend(argv, { "-c", nvim_console.command })
    return argv, nil
  end

  return nil, "unsupported ark.nvim console frontend: " .. tostring(frontend)
end

function M.shell_command(config, backend, session_id)
  local argv, err = M.argv(config, backend, session_id)
  if not argv then
    return nil, err
  end

  local escaped = {}
  for _, value in ipairs(argv) do
    escaped[#escaped + 1] = shellescape(value)
  end

  return table.concat(escaped, " "), nil
end

function M.nvim_console_bin(config)
  return nvim_console_config(config or {}).bin
end

return M
