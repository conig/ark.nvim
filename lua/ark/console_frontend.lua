local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function shellescape(value)
  return vim.fn.shellescape(tostring(value or ""))
end

local function normalize(value)
  if value == nil or value == "" or value == "raw" or value == "launcher" then
    return "raw"
  end
  return value
end

local function ark_terminal_config(config)
  local nested = type(config.ark_terminal) == "table" and config.ark_terminal or {}
  return {
    bin = nested.bin or config.ark_terminal_bin or "ark-terminal",
    raw = nested.raw ~= false,
    trace_log = nested.trace_log or config.ark_terminal_trace_log,
    print_status_json = nested.print_status_json == true or config.ark_terminal_print_status_json == true,
  }
end

local function nvim_console_config(config)
  local nested = type(config.nvim_console) == "table" and config.nvim_console or {}
  return {
    bin = nested.bin or config.nvim_console_bin or vim.v.progpath or "nvim",
    command = nested.command or "Ark console",
    add_repo_to_rtp = nested.add_repo_to_rtp ~= false,
  }
end

function M.normalize(value)
  return normalize(value)
end

function M.validate(value)
  local frontend = normalize(value)
  if frontend == "raw" or frontend == "ark-terminal" or frontend == "nvim-console" then
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
    local argv = { nvim_console.bin, "--cmd", "let g:ark_console_standalone = v:true" }
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

  local ark_terminal = ark_terminal_config(config)
  local argv = {
    ark_terminal.bin,
    "--backend",
    backend,
  }
  if ark_terminal.raw then
    argv[#argv + 1] = "--raw"
  end

  if type(config.startup_status_dir) == "string" and config.startup_status_dir ~= "" then
    vim.list_extend(argv, { "--status-dir", config.startup_status_dir })
  end
  if type(session_id) == "string" and session_id ~= "" then
    vim.list_extend(argv, { "--session-id", session_id })
  end
  if type(config.lsp_bin) == "string" and config.lsp_bin ~= "" then
    vim.list_extend(argv, { "--ark-lsp", config.lsp_bin })
  end
  if type(ark_terminal.trace_log) == "string" and ark_terminal.trace_log ~= "" then
    vim.list_extend(argv, { "--trace-log", ark_terminal.trace_log })
  end
  if ark_terminal.print_status_json then
    argv[#argv + 1] = "--print-status-json"
  end

  argv[#argv + 1] = "--"
  argv[#argv + 1] = config.launcher
  return argv, nil
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

function M.ark_terminal_bin(config)
  return ark_terminal_config(config or {}).bin
end

function M.nvim_console_bin(config)
  return nvim_console_config(config or {}).bin
end

return M
