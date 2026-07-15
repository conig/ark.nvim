local M = {}

local function extend(target, values)
  for _, value in ipairs(values or {}) do
    target[#target + 1] = value
  end
end

function M.display_args(opts)
  local args = {
    "display-popup",
    "-E",
    "-w",
    tostring(opts.width),
    "-h",
    tostring(opts.height),
    "-x",
    "C",
    "-y",
    "C",
  }
  if opts.border == false then
    args[#args + 1] = "-B"
  end
  if opts.border ~= false and type(opts.border_lines) == "string" and opts.border_lines ~= "" then
    extend(args, { "-b", opts.border_lines })
  end
  if type(opts.style) == "string" and opts.style ~= "" then
    extend(args, { "-s", opts.style })
  end
  if opts.border ~= false and type(opts.border_style) == "string" and opts.border_style ~= "" then
    extend(args, { "-S", opts.border_style })
  end
  for _, env in ipairs(opts.env or {}) do
    extend(args, { "-e", env })
  end
  if type(opts.target_client) == "string" and opts.target_client ~= "" then
    extend(args, { "-c", opts.target_client })
  else
    extend(args, { "-t", opts.target })
  end
  if type(opts.title) == "string" and opts.title ~= "" then
    extend(args, { "-T", opts.title })
  end
  args[#args + 1] = opts.command
  return args
end

function M.help_width(lines, title, opts, available, display_width, strip_ansi)
  if opts.width ~= nil and opts.width ~= "auto" then
    return tostring(opts.width)
  end
  local content_width = 0
  for _, line in ipairs(lines or {}) do
    content_width = math.max(content_width, display_width(strip_ansi(line or ""):gsub("%s+$", "")))
  end
  if type(title) == "string" and title ~= "" then
    content_width = math.max(content_width, display_width(title))
  end

  local max_width = available and math.floor(available * 0.9) or nil
  local min_width = tonumber(opts.min_width)
  min_width = min_width and min_width > 0 and math.floor(min_width) or 40
  if max_width then
    min_width = math.min(min_width, max_width)
  end
  local desired = math.max(min_width, content_width + 4)
  if max_width then
    desired = math.min(desired, max_width)
  end
  return tostring(math.max(1, desired))
end

function M.launcher_lines(command, escaped_cleanup_paths)
  return {
    "#!/bin/sh",
    command,
    "status=$?",
    "rm -f -- " .. table.concat(escaped_cleanup_paths or {}, " "),
    "exit $status",
  }
end

function M.cleaned_command(command, escaped_cleanup_paths)
  return command
    .. "; status=$?; rm -f -- "
    .. table.concat(escaped_cleanup_paths or {}, " ")
    .. "; exit $status"
end

return M
