-- Append-only project logs avoid lost updates between independent consoles.
-- Recall is bounded; disk retention is explicit (users may delete old logs).
local M = {}
local uv = vim.uv or vim.loop

function M.open(cwd, options, markers)
  options = options or {}
  local store = { max_entries = math.max(1, math.floor(tonumber(options.max_entries) or 1000)) }
  if options.enabled == false then
    return store
  end
  local root = vim.fs.root(cwd, markers or { ".git", ".Rproj", "DESCRIPTION", "renv.lock" }) or cwd
  root = uv.fs_realpath(root) or vim.fs.normalize(root)
  local directory = options.directory or (vim.fn.stdpath("state") .. "/ark/console-history")
  store.path = vim.fs.normalize(directory .. "/" .. vim.fn.sha256(root) .. ".jsonl")
  return store
end

function M.load(store)
  if not store.path then
    return {}
  end
  local file, err = io.open(store.path, "r")
  if not file then
    if not uv.fs_stat(store.path) then
      return {}
    end
    return {}, err
  end
  local ring, count, previous = {}, 0, nil
  local read_ok, read_err = pcall(function()
    for line in file:lines() do
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "string" and entry:find("%S") and entry ~= previous then
        count = count + 1
        ring[(count - 1) % store.max_entries + 1] = entry
        previous = entry
      end
    end
  end)
  file:close()
  if not read_ok then
    return {}, read_err
  end
  local entries = {}
  for index = math.max(1, count - store.max_entries + 1), count do
    entries[#entries + 1] = ring[(index - 1) % store.max_entries + 1]
  end
  return entries
end

function M.append(store, text)
  if not store.path or not text:find("%S") then
    return true
  end
  local ok, err = pcall(vim.fn.mkdir, vim.fs.dirname(store.path), "p", 448)
  if not ok then
    return nil, err
  end
  local fd, open_err = uv.fs_open(store.path, "a", 384)
  if not fd then
    return nil, open_err
  end
  -- A leading newline isolates a previous interrupted/partial write.
  -- One O_APPEND write keeps concurrent writers' complete records separate.
  local record = "\n" .. vim.json.encode(text) .. "\n"
  local written, write_err = uv.fs_write(fd, record, -1)
  local closed, close_err = uv.fs_close(fd)
  if written ~= #record then
    return nil, write_err or "incomplete history write"
  end
  if not closed then
    return nil, close_err
  end
  return true
end

return M
