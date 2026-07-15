local M = {}

function M.trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.command(args)
  local command = { "tmux" }
  local socket = vim.env.ARK_TMUX_SOCKET
  if type(socket) ~= "string" or socket == "" then
    local tmux_env = vim.env.TMUX
    if type(tmux_env) == "string" and tmux_env ~= "" then
      socket = vim.split(tmux_env, ",", { plain = true })[1]
    end
  end
  if type(socket) == "string" and socket ~= "" then
    command[#command + 1] = "-S"
    command[#command + 1] = socket
  end
  vim.list_extend(command, args or {})
  return command
end

function M.run(args)
  local output = vim.fn.system(M.command(args))
  if vim.v.shell_error ~= 0 then
    return nil, M.trim(output)
  end
  return M.trim(output), nil
end

function M.start(args, job_opts)
  local ok, job_id = pcall(vim.fn.jobstart, M.command(args), job_opts or { detach = true })
  if not ok then
    return nil, tostring(job_id)
  end
  if type(job_id) ~= "number" or job_id <= 0 then
    return nil, "failed to start tmux command"
  end
  return true, nil
end

function M.strip_ansi(text)
  return (text or ""):gsub("\27%[[0-9;]*[%a]", "")
end

function M.shell_join(args)
  local escaped = {}
  for _, arg in ipairs(args or {}) do
    escaped[#escaped + 1] = vim.fn.shellescape(tostring(arg))
  end
  return table.concat(escaped, " ")
end

return M
