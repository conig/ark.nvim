local uv = vim.uv or vim.loop

local M = {}

local DEFAULT_MAX_FILES = 128
local DEFAULT_MAX_FILE_BYTES = 1024 * 1024
local unpack = table.unpack or unpack
local static_manifest_cache = {}

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(path)
end

local function joinpath(...)
  if vim.fs and type(vim.fs.joinpath) == "function" then
    return vim.fs.joinpath(...)
  end
  return table.concat({ ... }, "/"):gsub("/+", "/")
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function collapse_ws(value)
  value = trim(value)
  return (value:gsub("%s+", " "))
end

local function is_ident_start(char)
  return char:match("[%a_.]") ~= nil
end

local function is_ident_char(char)
  return char:match("[%w_.]") ~= nil
end

local function parse_identifier(text, index)
  local len = #text
  local char = text:sub(index, index)
  if char == "" or not is_ident_start(char) then
    return nil, index
  end

  local cursor = index + 1
  while cursor <= len and is_ident_char(text:sub(cursor, cursor)) do
    cursor = cursor + 1
  end

  return text:sub(index, cursor - 1), cursor
end

local function skip_ws(text, index)
  local cursor = index
  while cursor <= #text and text:sub(cursor, cursor):match("%s") do
    cursor = cursor + 1
  end
  return cursor
end

local function accepted_call(namespace, name)
  if name == "source" then
    return namespace == nil
  end
  if name == "tar_source" then
    return namespace == nil or namespace == "targets"
  end
  if name == "tar_target" then
    return namespace == nil or namespace == "targets"
  end
  if name == "tar_target_raw" then
    return namespace == nil or namespace == "targets"
  end
  if name == "tar_combine" then
    return namespace == nil or namespace == "tarchetypes"
  end
  if name == "tar_render" then
    return namespace == nil or namespace == "tarchetypes"
  end
  return false
end

local function extract_balanced_call(text, call_start, open_index)
  local depth = 0
  local quote = nil
  local comment = false
  local cursor = open_index

  while cursor <= #text do
    local char = text:sub(cursor, cursor)

    if quote then
      if quote ~= "`" and char == "\\" then
        cursor = cursor + 2
      elseif char == quote then
        quote = nil
        cursor = cursor + 1
      else
        cursor = cursor + 1
      end
    elseif comment then
      if char == "\n" then
        comment = false
      end
      cursor = cursor + 1
    elseif char == "#" then
      comment = true
      cursor = cursor + 1
    elseif char == "'" or char == '"' or char == "`" then
      quote = char
      cursor = cursor + 1
    elseif char == "(" then
      depth = depth + 1
      cursor = cursor + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(call_start, cursor), cursor
      end
      cursor = cursor + 1
    else
      cursor = cursor + 1
    end
  end

  return nil, nil
end

local function each_call(text, visitor)
  local cursor = 1
  local quote = nil
  local comment = false

  while cursor <= #text do
    local char = text:sub(cursor, cursor)

    if quote then
      if quote ~= "`" and char == "\\" then
        cursor = cursor + 2
      elseif char == quote then
        quote = nil
        cursor = cursor + 1
      else
        cursor = cursor + 1
      end
    elseif comment then
      if char == "\n" then
        comment = false
      end
      cursor = cursor + 1
    elseif char == "#" then
      comment = true
      cursor = cursor + 1
    elseif char == "'" or char == '"' or char == "`" then
      quote = char
      cursor = cursor + 1
    elseif is_ident_start(char) then
      local call_start = cursor
      local first, after_first = parse_identifier(text, cursor)
      local namespace = nil
      local name = first
      local after_name = after_first

      if text:sub(after_first, after_first + 1) == "::" then
        local second, after_second = parse_identifier(text, after_first + 2)
        if second then
          namespace = first
          name = second
          after_name = after_second
        end
      end

      local open_index = skip_ws(text, after_name)
      if accepted_call(namespace, name) and text:sub(open_index, open_index) == "(" then
        local call_text, close_index = extract_balanced_call(text, call_start, open_index)
        if call_text then
          visitor({
            namespace = namespace,
            name = name,
            start = call_start,
            open = open_index,
            close = close_index,
            text = call_text,
          })
          cursor = close_index + 1
        else
          cursor = after_name
        end
      else
        cursor = after_name
      end
    else
      cursor = cursor + 1
    end
  end
end

local function split_args(arg_text)
  local args = {}
  local start = 1
  local cursor = 1
  local quote = nil
  local comment = false
  local paren = 0
  local bracket = 0
  local brace = 0

  while cursor <= #arg_text do
    local char = arg_text:sub(cursor, cursor)

    if quote then
      if quote ~= "`" and char == "\\" then
        cursor = cursor + 2
      elseif char == quote then
        quote = nil
        cursor = cursor + 1
      else
        cursor = cursor + 1
      end
    elseif comment then
      if char == "\n" then
        comment = false
      end
      cursor = cursor + 1
    elseif char == "#" then
      comment = true
      cursor = cursor + 1
    elseif char == "'" or char == '"' or char == "`" then
      quote = char
      cursor = cursor + 1
    elseif char == "(" then
      paren = paren + 1
      cursor = cursor + 1
    elseif char == ")" then
      paren = math.max(0, paren - 1)
      cursor = cursor + 1
    elseif char == "[" then
      bracket = bracket + 1
      cursor = cursor + 1
    elseif char == "]" then
      bracket = math.max(0, bracket - 1)
      cursor = cursor + 1
    elseif char == "{" then
      brace = brace + 1
      cursor = cursor + 1
    elseif char == "}" then
      brace = math.max(0, brace - 1)
      cursor = cursor + 1
    elseif char == "," and paren == 0 and bracket == 0 and brace == 0 then
      args[#args + 1] = trim(arg_text:sub(start, cursor - 1))
      start = cursor + 1
      cursor = cursor + 1
    else
      cursor = cursor + 1
    end
  end

  local final = trim(arg_text:sub(start))
  if final ~= "" then
    args[#args + 1] = final
  end

  return args
end

local function call_args(text, call)
  return split_args(text:sub(call.open + 1, call.close - 1))
end

local function unnamed_arg(value, accepted_name)
  value = trim(value)
  local name, rest = value:match("^([%a_][%w_.]*)%s*=%s*(.+)$")
  if name == accepted_name then
    return trim(rest)
  end
  return value
end

local function named_arg(value)
  value = trim(value)
  local name, rest = value:match("^([%a_][%w_.]*)%s*=%s*(.+)$")
  if name then
    return name, trim(rest)
  end
  return nil, value
end

local function parse_target_name(value)
  value = unnamed_arg(value, "name")
  if value == "" then
    return nil
  end

  local backtick = value:match("^`([^`]+)`")
  if backtick and backtick ~= "" then
    return backtick
  end

  local quoted = value:match("^[\"']([^\"']+)[\"']")
  if quoted and quoted ~= "" then
    return quoted
  end

  return value:match("^([%a_.][%w_.]*)")
end

local function parse_string(value)
  value = unnamed_arg(value, "file")
  value = trim(value)

  local quote = value:sub(1, 1)
  if quote ~= "'" and quote ~= '"' then
    return nil
  end

  local escaped = false
  for index = 2, #value do
    local char = value:sub(index, index)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == quote then
      return value:sub(2, index - 1)
    end
  end

  return nil
end

local function parse_path_expr(value)
  local direct = parse_string(value)
  if direct then
    return direct
  end

  if not value:match("^file%.path%s*%(") then
    return nil
  end

  local inner = value:match("^file%.path%s*%((.*)%)%s*$")
  local parts = {}
  for _, arg in ipairs(split_args(inner or "")) do
    local part = parse_string(arg)
    if not part then
      return nil
    end
    parts[#parts + 1] = part
  end

  if #parts == 0 then
    return nil
  end

  return joinpath(unpack(parts))
end

local function parse_path_values(value)
  value = trim(value)
  if value == "" then
    return {}
  end

  local vector = value:match("^c%s*%((.*)%)%s*$")
  if vector then
    local paths = {}
    for _, arg in ipairs(split_args(vector)) do
      local path = parse_path_expr(arg)
      if path then
        paths[#paths + 1] = path
      end
    end
    return paths
  end

  local path = parse_path_expr(value)
  if not path then
    return {}
  end
  return { path }
end

local function source_arg_paths(call_name, args)
  local accepted_names = call_name == "tar_source" and { "files" } or { "file" }
  local positional = nil

  for _, arg in ipairs(args) do
    local name, rest = named_arg(arg)
    if name then
      for _, accepted in ipairs(accepted_names) do
        if name == accepted then
          return parse_path_values(rest)
        end
      end
    elseif positional == nil then
      positional = rest
    end
  end

  if positional then
    return parse_path_values(positional)
  end

  if call_name == "tar_source" then
    return { "R" }
  end
  return {}
end

local function line_for_offset(text, offset)
  local prefix = text:sub(1, math.max(0, offset - 1))
  local _, count = prefix:gsub("\n", "")
  return count + 1
end

local function file_mtime(path)
  if type(path) ~= "string" or path == "" or not uv or type(uv.fs_stat) ~= "function" then
    return nil
  end
  local stat = uv.fs_stat(path)
  if type(stat) ~= "table" or type(stat.mtime) ~= "table" then
    return nil
  end
  return (tonumber(stat.mtime.sec) or 0) + ((tonumber(stat.mtime.nsec) or 0) / 1e9)
end

local function read_text(path, opts)
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  local max_bytes = opts.max_file_bytes or DEFAULT_MAX_FILE_BYTES
  if stat and type(stat.size) == "number" and stat.size > max_bytes then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return table.concat(lines, "\n")
end

local function split_pipe(line)
  local fields = {}
  for field in (line .. "|"):gmatch("([^|]*)|") do
    fields[#fields + 1] = field
  end
  return fields
end

local function read_pipe_table(path, opts)
  local text = read_text(path, opts)
  if not text or text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true, trimempty = true })
  if #lines < 2 then
    return {}
  end

  local header = split_pipe(lines[1])
  local records = {}
  for index = 2, #lines do
    local fields = split_pipe(lines[index])
    local record = {}
    for field_index, key in ipairs(header) do
      record[key] = fields[field_index] or ""
    end
    records[#records + 1] = record
  end

  return records
end

local function add_file(files, seen, path, opts)
  path = normalize(path)
  if not path or seen[path] or #files >= (opts.max_files or DEFAULT_MAX_FILES) then
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    return
  end
  seen[path] = true
  files[#files + 1] = path
end

local function remember_scanned_dir(dir, opts)
  dir = normalize(dir)
  if not dir or type(opts._scanned_dirs) ~= "table" or type(opts._seen_scanned_dirs) ~= "table" then
    return
  end
  if opts._seen_scanned_dirs[dir] then
    return
  end

  opts._seen_scanned_dirs[dir] = true
  opts._scanned_dirs[#opts._scanned_dirs + 1] = dir
end

local function scan_dir(dir, files, seen, opts)
  if not uv or type(uv.fs_scandir) ~= "function" then
    return
  end

  remember_scanned_dir(dir, opts)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end

  local entries = {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[#entries + 1] = { name = name, kind = kind }
  end

  table.sort(entries, function(left, right)
    return left.name < right.name
  end)

  for _, entry in ipairs(entries) do
    if #files >= (opts.max_files or DEFAULT_MAX_FILES) then
      return
    end
    if entry.name:sub(1, 1) ~= "." then
      local path = joinpath(dir, entry.name)
      if entry.kind == "directory" then
        scan_dir(path, files, seen, opts)
      elseif entry.kind == "file" and path:match("%.R$") then
        add_file(files, seen, path, opts)
      end
    end
  end
end

local function resolve_relative(base_file, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return normalize(path)
  end
  return normalize(joinpath(vim.fs.dirname(base_file), path))
end

local function source_paths(path, text)
  local paths = {}
  each_call(text, function(call)
    if call.name ~= "source" and call.name ~= "tar_source" then
      return
    end

    local args = call_args(text, call)
    for _, source in ipairs(source_arg_paths(call.name, args)) do
      local resolved = resolve_relative(path, source)
      if resolved then
        paths[#paths + 1] = resolved
      end
    end
  end)
  return paths
end

local function collect_files(project, opts)
  opts = vim.tbl_extend("force", opts or {}, {
    _scanned_dirs = {},
    _seen_scanned_dirs = {},
  })
  local files = {}
  local seen = {}
  local script = normalize(project and project.script)
  if not script then
    return files, opts._scanned_dirs
  end

  add_file(files, seen, script, opts)

  local root = normalize(project and project.root)
  if root then
    scan_dir(joinpath(root, "_target_pipelines"), files, seen, opts)
  end

  local index = 1
  while index <= #files and #files < (opts.max_files or DEFAULT_MAX_FILES) do
    local path = files[index]
    local text = read_text(path, opts)
    if text then
      for _, source in ipairs(source_paths(path, text)) do
        if vim.fn.isdirectory(source) == 1 then
          scan_dir(source, files, seen, opts)
        else
          add_file(files, seen, source, opts)
        end
      end
    end
    index = index + 1
  end

  return files, opts._scanned_dirs
end

local function parse_targets(path, text)
  local records = {}

  each_call(text, function(call)
    if
      call.name ~= "tar_target"
      and call.name ~= "tar_target_raw"
      and call.name ~= "tar_combine"
      and call.name ~= "tar_render"
    then
      return
    end

    local args = call_args(text, call)
    local name = parse_target_name(args[1] or "")
    if not name or name == "" then
      return
    end

    local command = (call.name == "tar_target" or call.name == "tar_target_raw") and collapse_ws(args[2] or "")
      or collapse_ws(call.text)
    records[#records + 1] = {
      name = name,
      command = command,
      source = "static",
      declaration = call.name,
      path = path,
      line = line_for_offset(text, call.start),
      call = trim(call.text),
    }
  end)

  return records
end

local function source_records(files, opts)
  local records = {}
  for _, path in ipairs(files) do
    local text = read_text(path, opts)
    if text then
      vim.list_extend(records, parse_targets(path, text))
    end
  end
  return records
end

local function source_newer_than(path, files)
  local marker_mtime = file_mtime(path)
  if not marker_mtime then
    return true
  end

  for _, source in ipairs(files or {}) do
    local source_mtime = file_mtime(source)
    if source_mtime and source_mtime > marker_mtime then
      return true
    end
  end

  return false
end

local function build_generator_index(records)
  local by_name = {}
  for _, record in ipairs(records or {}) do
    local name = record.name
    if type(name) == "string" and name ~= "" then
      by_name[name] = by_name[name] or record
    end
  end
  return by_name
end

local function find_generator(name, by_name)
  if type(name) ~= "string" or name == "" then
    return nil
  end

  local exact = by_name[name]
  if exact then
    return exact
  end

  local best = nil
  local best_len = 0
  for stem, record in pairs(by_name or {}) do
    local prefix = stem .. "_"
    if #stem > best_len and name:sub(1, #prefix) == prefix then
      best = record
      best_len = #stem
    end
  end
  return best
end

local function progress_manifest(project, files, source_records_list, opts)
  local store = normalize(project and project.store)
  if not store then
    return nil
  end

  local path = joinpath(store, "meta", "progress")
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  if source_newer_than(path, files) then
    return nil
  end

  local rows = read_pipe_table(path, opts)
  if #rows == 0 then
    return nil
  end

  local by_name = build_generator_index(source_records_list)
  local targets = {}
  local seen = {}

  for _, row in ipairs(rows) do
    local name = row.name
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      local generator = find_generator(name, by_name)
      targets[#targets + 1] = {
        name = name,
        command = generator and generator.command or "",
        source = "targets-cache",
        cache_source = path,
        path = generator and generator.path or path,
        line = generator and generator.line or nil,
        call = generator and generator.call or "",
        declaration = generator and generator.declaration or "",
        generator_name = generator and generator.name or nil,
        target_type = row.type,
        parent = row.parent,
        branches = row.branches,
        progress = row.progress,
      }
    end
  end

  if #targets == 0 then
    return nil
  end

  return targets
end

local function cache_key(project, opts)
  project = project or {}
  opts = opts or {}
  return table.concat({
    normalize(project.root) or "",
    normalize(project.script) or "",
    normalize(project.store) or "",
    tostring(opts.max_files or DEFAULT_MAX_FILES),
    tostring(opts.max_file_bytes or DEFAULT_MAX_FILE_BYTES),
  }, "\0")
end

local function path_signature(path)
  path = normalize(path)
  if not path or not uv or type(uv.fs_stat) ~= "function" then
    return "missing"
  end

  local stat = uv.fs_stat(path)
  if type(stat) ~= "table" then
    return "missing"
  end

  local mtime = stat.mtime or {}
  return table.concat({
    stat.type or "",
    tostring(stat.size or ""),
    tostring(mtime.sec or ""),
    tostring(mtime.nsec or ""),
  }, ":")
end

local function dependency_signature(project, files, dirs)
  local entries = {}

  local function add(kind, path)
    path = normalize(path)
    if not path then
      return
    end
    entries[#entries + 1] = table.concat({
      kind,
      path,
      path_signature(path),
    }, "\t")
  end

  for _, path in ipairs(files or {}) do
    add("file", path)
  end
  for _, dir in ipairs(dirs or {}) do
    add("dir", dir)
  end

  local store = normalize(project and project.store)
  if store then
    add("file", joinpath(store, "meta", "progress"))
  end

  table.sort(entries)
  return table.concat(entries, "\n")
end

local function cached_manifest(project, opts, started)
  local entry = static_manifest_cache[cache_key(project, opts)]
  if type(entry) ~= "table" then
    return nil
  end
  if dependency_signature(project, entry.files, entry.dirs) ~= entry.dependency_signature then
    return nil
  end

  local payload = vim.deepcopy(entry.payload)
  payload.elapsed_ms = math.floor((((uv and uv.hrtime and uv.hrtime()) or vim.loop.hrtime()) - started) / 1e6)
  return payload
end

function M.static_manifest(project, opts)
  opts = opts or {}
  local started = (uv and uv.hrtime and uv.hrtime()) or vim.loop.hrtime()
  local cached = cached_manifest(project or {}, opts, started)
  if cached then
    return cached
  end

  local targets = nil
  local manifest_source = "static"
  local seen_names = {}
  local files, dirs = collect_files(project or {}, opts)
  local parsed_sources = source_records(files, opts)

  targets = progress_manifest(project or {}, files, parsed_sources, opts)

  if targets then
    manifest_source = "targets-cache"
  else
    targets = {}
    for _, record in ipairs(parsed_sources) do
      if not seen_names[record.name] then
        seen_names[record.name] = true
        targets[#targets + 1] = record
      end
    end
  end

  local elapsed_ms = math.floor((((uv and uv.hrtime and uv.hrtime()) or vim.loop.hrtime()) - started) / 1e6)
  local payload = {
    schema_version = 1,
    status = "ok",
    project = project,
    source = manifest_source,
    targets = targets,
    files = files,
    elapsed_ms = elapsed_ms,
  }
  static_manifest_cache[cache_key(project or {}, opts)] = {
    files = vim.deepcopy(files),
    dirs = vim.deepcopy(dirs),
    dependency_signature = dependency_signature(project or {}, files, dirs),
    payload = vim.deepcopy(payload),
  }
  return payload
end

return M
