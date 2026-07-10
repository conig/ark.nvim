local M = {}

function M.new(deps)
  local Controller = {
    refresh = deps.refresh,
    send = deps.send,
  }
  local add_candidate_bufnr = deps.add_candidate_bufnr
  local current_nvim_server = deps.current_nvim_server
  local ensure_runtime_ready = deps.ensure_runtime_ready
  local ensure_setup = deps.ensure_setup
  local expression = deps.expression
  local is_ark_runtime_buffer = deps.is_ark_runtime_buffer
  local lsp = deps.lsp
  local normalize_view_display = deps.normalize_view_display
  local notify = deps.notify
  local options = deps.options
  local resolve_bufnr = deps.resolve_bufnr
  local resolve_view_source_bufnr = deps.resolve_view_source_bufnr
  local r_string_literal = deps.r_string_literal
  local session_backend = deps.session_backend
  local should_use_tmux_view_popup = deps.should_use_tmux_view_popup
  local target_tools = deps.target_tools
  local target_view = deps.target_view
  local view = deps.view
  local view_popup_backend = deps.view_popup_backend
  local with_runtime_ready = deps.with_runtime_ready
  local tar_read_target_name

  local function targets_trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  
  local function targets_config_path(root)
    local config = vim.env.TAR_CONFIG
    if type(config) ~= "string" or config == "" then
      config = "_targets.yaml"
    end
    if config:sub(1, 1) == "/" then
      return vim.fs.normalize(config)
    end
    return vim.fs.normalize(root .. "/" .. config)
  end
  
  local function targets_yaml_scalar(value)
    value = targets_trim(value or "")
    if value == "" or value == "null" or value == "~" then
      return nil
    end
  
    local quote = value:sub(1, 1)
    if (quote == '"' or quote == "'") and value:sub(-1) == quote then
      return value:sub(2, -2)
    end
    return value
  end
  
  local function targets_config_value(root, name)
    local config = targets_config_path(root)
    if vim.fn.filereadable(config) ~= 1 then
      return nil
    end
  
    local ok, lines = pcall(vim.fn.readfile, config, "", 2000)
    if not ok or type(lines) ~= "table" then
      return nil
    end
  
    local project = vim.env.TAR_PROJECT
    if type(project) ~= "string" or project == "" then
      project = "main"
    end
  
    local in_project = false
    for _, line in ipairs(lines) do
      local top = line:match("^([%w_.-]+):%s*$")
      if top then
        in_project = top == project
      elseif in_project then
        local value = line:match("^%s+" .. name .. ":%s*(.-)%s*$")
        if value then
          return targets_yaml_scalar(value)
        end
      end
    end
  
    for _, line in ipairs(lines) do
      local value = line:match("^" .. name .. ":%s*(.-)%s*$")
      if value then
        return targets_yaml_scalar(value)
      end
    end
  
    return nil
  end
  
  local function targets_resolve_project_path(root, path)
    if type(path) ~= "string" or path == "" then
      return nil
    end
    if path:sub(1, 1) == "/" then
      return vim.fs.normalize(path)
    end
    return vim.fs.normalize(root .. "/" .. path)
  end
  
  local function targets_project_script(root)
    return targets_resolve_project_path(root, targets_config_value(root, "script"))
      or vim.fs.normalize(root .. "/_targets.R")
  end
  
  local function targets_project_store_path(root)
    return targets_resolve_project_path(root, targets_config_value(root, "store"))
      or vim.fs.normalize(root .. "/_targets")
  end
  
  local function targets_project(bufnr)
    bufnr = resolve_bufnr(bufnr)
    local path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
    local anchor = path ~= "" and path or vim.loop.cwd()
    local root = vim.fs.root(anchor, { "_targets.R", "_targets.yaml", ".git" }) or vim.loop.cwd()
    root = vim.fs.normalize(root)
    local script = targets_project_script(root)
    local store = targets_project_store_path(root)
  
    return {
      root = root,
      script = script,
      store = store,
    }
  end
  
  function Controller.targets_project(bufnr)
    return targets_project(bufnr)
  end
  
  function Controller.targets_script(bufnr)
    return targets_project(bufnr).script
  end
  
  local target_runtime_by_root = {}
  
  local function same_targets_project(project, bufnr)
    if type(project) ~= "table" or type(project.root) ~= "string" or project.root == "" then
      return false
    end
    if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    return targets_project(bufnr).root == project.root
  end
  
  local function target_runtime_candidate(project, bufnr)
    if is_ark_runtime_buffer(bufnr) and same_targets_project(project, bufnr) then
      return bufnr
    end
    return nil
  end
  
  local function target_runtime_filetype()
    local filetypes = options and options.filetypes or nil
    if vim.tbl_contains(filetypes or {}, "r") then
      return "r"
    end
    return (type(filetypes) == "table" and filetypes[1]) or "r"
  end
  
  local function ensure_target_script_buffer(project)
    local script = type(project) == "table" and project.script or nil
    if type(script) ~= "string" or script == "" or vim.fn.filereadable(script) ~= 1 then
      return nil
    end
  
    local bufnr = vim.fn.bufnr(script)
    local existed = bufnr > 0
    if not existed then
      bufnr = vim.fn.bufadd(script)
    end
    if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
  
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    if not existed then
      vim.bo[bufnr].buflisted = false
    end
    if not vim.tbl_contains(options.filetypes or {}, vim.bo[bufnr].filetype) then
      vim.bo[bufnr].filetype = target_runtime_filetype()
    end
  
    if target_runtime_candidate(project, bufnr) then
      target_runtime_by_root[project.root] = bufnr
      return bufnr
    end
    return nil
  end
  
  local function targets_runtime_bufnr(project, anchor_bufnr)
    local candidates = {}
    local seen = {}
  
    add_candidate_bufnr(candidates, seen, anchor_bufnr)
    add_candidate_bufnr(candidates, seen, target_runtime_by_root[project.root])
    add_candidate_bufnr(candidates, seen, vim.fn.bufnr("#"))
  
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(winid) then
        add_candidate_bufnr(candidates, seen, vim.api.nvim_win_get_buf(winid))
      end
    end
  
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      add_candidate_bufnr(candidates, seen, bufnr)
    end
  
    for _, candidate in ipairs(candidates) do
      local runtime_bufnr = target_runtime_candidate(project, candidate)
      if runtime_bufnr then
        target_runtime_by_root[project.root] = runtime_bufnr
        return runtime_bufnr
      end
    end
  
    return ensure_target_script_buffer(project)
  end
  
  local function target_name_text(value)
    if type(value) == "string" then
      return value
    elseif type(value) == "number" then
      return tostring(value)
    end
    return ""
  end
  
  local function normalize_target_names(value)
    if type(value) == "table" then
      local names = {}
      for _, item in ipairs(value) do
        local name = target_name_text(item)
        if name ~= "" then
          names[#names + 1] = name
        end
      end
      return names
    end
  
    if type(value) ~= "string" or value == "" then
      return {}
    end
  
    local names = {}
    for name in value:gmatch("[^,%s]+") do
      names[#names + 1] = name
    end
    return names
  end
  
  local function r_symbol_or_string(value)
    local name = target_name_text(value)
    if name:match("^%.?[A-Za-z][A-Za-z0-9._]*$") and not name:match("^%.[0-9]") then
      return name
    end
    return r_string_literal(name)
  end
  
  local function target_load_expression(names)
    if type(names) ~= "table" or #names == 0 then
      return "targets::tar_load()"
    end
  
    if #names == 1 then
      return string.format("targets::tar_load(%s)", r_symbol_or_string(names[1]))
    end
  
    local rendered = {}
    for _, name in ipairs(names) do
      rendered[#rendered + 1] = r_symbol_or_string(name)
    end
    return string.format("targets::tar_load(c(%s))", table.concat(rendered, ", "))
  end
  
  tar_read_target_name = function(expr)
    if type(expr) ~= "string" or expr == "" then
      return nil
    end
  
    local callees = {
      "tar_read",
      "targets::tar_read",
      "targets:::tar_read",
    }
    local arg_patterns = {
      "name%s*=%s*\"([^\"]+)\"",
      "name%s*=%s*'([^']+)'",
      "\"([^\"]+)\"",
      "'([^']+)'",
      "name%s*=%s*([%.%a_][%w_.]*)",
      "([%.%a_][%w_.]*)",
    }
  
    for _, callee in ipairs(callees) do
      local escaped = vim.pesc(callee)
      for _, arg_pattern in ipairs(arg_patterns) do
        local name = expr:match("^%s*" .. escaped .. "%s*%(%s*" .. arg_pattern .. "%s*%)%s*$")
        if type(name) == "string" and name ~= "" then
          return name
        end
      end
    end
  
    return nil
  end
  
  local function description_file_for_buffer(bufnr)
    local path = ""
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      path = vim.api.nvim_buf_get_name(bufnr)
    end
  
    local start = ""
    if type(path) == "string" and path ~= "" then
      start = vim.fn.fnamemodify(path, ":p:h")
    elseif uv and type(uv.cwd) == "function" then
      start = uv.cwd()
    else
      start = vim.fn.getcwd()
    end
  
    if type(start) ~= "string" or start == "" then
      return ""
    end
  
    local found = vim.fs.find("DESCRIPTION", {
      path = start,
      upward = true,
      type = "file",
    })[1]
  
    return found and vim.fs.normalize(found) or ""
  end
  
  local function missing_packages_from_diagnostics(bufnr)
    bufnr = resolve_bufnr(bufnr)
  
    local seen = {}
    local packages = {}
    for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
      local package = tostring(diagnostic.message or ""):match("^Package '([^']+)' is not installed%.$")
      if package and not seen[package] then
        seen[package] = true
        packages[#packages + 1] = package
      end
    end
  
    table.sort(packages)
    return packages
  end
  
  local function package_install_message(result)
    if type(result) ~= "table" then
      return "R package install completed"
    end
  
    local packages = result.packages
    if type(packages) ~= "table" or #packages == 0 then
      packages = result.specs
    end
    if type(packages) ~= "table" or #packages == 0 then
      return "R package install completed"
    end
  
    local verb = #packages == 1 and "package" or "packages"
    local method = type(result.method) == "string" and result.method ~= "" and result.method or "R"
    return string.format("Installed R %s with %s: %s", verb, method, table.concat(packages, ", "))
  end
  
  local function package_install_request_async(bufnr, packages, description, dry_run, callback)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
  
    local function request_install(runtime_err)
      if runtime_err then
        notify(runtime_err, vim.log.levels.WARN)
        if type(callback) == "function" then
          callback(nil, runtime_err)
        end
        return nil, runtime_err
      end
  
      return lsp.package_install_async(options, bufnr, packages, description, dry_run, function(result, err)
        if err then
          notify(err or "package install failed", vim.log.levels.WARN)
          if type(callback) == "function" then
            callback(nil, err)
          end
          return
        end
  
        if type(callback) == "function" then
          callback(result, nil)
        end
      end)
    end
  
    local ok, runtime_err, err_source = with_runtime_ready(bufnr, "ark.nvim package install", request_install)
    if not ok and runtime_err and err_source ~= "callback" then
      notify(runtime_err, vim.log.levels.WARN)
      if type(callback) == "function" then
        callback(nil, runtime_err)
      end
      return nil, runtime_err
    end
    if not ok and runtime_err then
      return nil, runtime_err
    end
  
    return ok
  end
  
  local function targets_request(bufnr, label, request)
    ensure_setup()
    local anchor_bufnr = resolve_bufnr(bufnr)
    local project = targets_project(anchor_bufnr)
    local target_bufnr = targets_runtime_bufnr(project, anchor_bufnr)
    if not target_bufnr then
      local err = (label or "ark.nvim target lens") .. " requires an R-family buffer or readable targets script"
      notify(err, vim.log.levels.WARN)
      return nil, err
    end
  
    local ok, runtime_err = ensure_runtime_ready(target_bufnr, label or "ark.nvim target lens")
    if not ok then
      notify(runtime_err, vim.log.levels.WARN)
      return nil, runtime_err
    end
  
    local result, err = nil, nil
    for attempt = 1, 5 do
      result, err = request(project, target_bufnr)
      if result then
        return result
      end
  
      local err_text = tostring(err or "")
      local transient = err_text:find("Resource temporarily unavailable", 1, true) ~= nil
        or err_text:find("bridge connection failed", 1, true) ~= nil
      if not transient or attempt == 5 then
        break
      end
      vim.wait(150 * attempt, function()
        return false
      end, 150 * attempt, false)
    end
  
    notify(err or "target request failed", vim.log.levels.WARN)
    return nil, err
  end
  
  local function targets_request_async(bufnr, label, request, callback)
    ensure_setup()
    local anchor_bufnr = resolve_bufnr(bufnr)
    label = label or "ark.nvim target lens"
    local project = targets_project(anchor_bufnr)
    local target_bufnr = targets_runtime_bufnr(project, anchor_bufnr)
    if not target_bufnr then
      local err = label .. " requires an R-family buffer or readable targets script"
      notify(err, vim.log.levels.WARN)
      if type(callback) == "function" then
        callback(nil, err)
      end
      return nil, err
    end
  
    local function request_targets(runtime_err)
      if runtime_err then
        notify(runtime_err, vim.log.levels.WARN)
        if type(callback) == "function" then
          callback(nil, runtime_err)
        end
        return nil, runtime_err
      end
  
      local attempt = 0
      local request_once
  
      local function handle_result(result, err)
        if result then
          if type(callback) == "function" then
            callback(result, nil)
          end
          return
        end
  
        local err_text = tostring(err or "")
        local transient = err_text:find("Resource temporarily unavailable", 1, true) ~= nil
          or err_text:find("bridge connection failed", 1, true) ~= nil
        if transient and attempt < 5 then
          vim.defer_fn(function()
            request_once()
          end, 150 * attempt)
          return
        end
  
        notify(err or "target request failed", vim.log.levels.WARN)
        if type(callback) == "function" then
          callback(nil, err)
        end
      end
  
      request_once = function()
        attempt = attempt + 1
        local sent, send_err = request(project, target_bufnr, handle_result)
        if not sent then
          handle_result(nil, send_err)
        end
      end
  
      request_once()
      return true
    end
  
    local ok, runtime_err, err_source = with_runtime_ready(target_bufnr, label, request_targets)
    if not ok and runtime_err and err_source ~= "callback" then
      notify(runtime_err, vim.log.levels.WARN)
      if type(callback) == "function" then
        callback(nil, runtime_err)
      end
      return nil, runtime_err
    end
    if not ok and runtime_err then
      return nil, runtime_err
    end
  
    return ok
  end
  
  function Controller.missing_packages(bufnr)
    ensure_setup()
    return missing_packages_from_diagnostics(bufnr)
  end
  
  function Controller.install_missing_packages(bufnr, install_opts)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
    install_opts = install_opts or {}
  
    local raw_packages = install_opts.packages or missing_packages_from_diagnostics(bufnr)
    if type(raw_packages) ~= "table" then
      raw_packages = {}
    end
  
    local seen = {}
    local packages = {}
    for _, package in ipairs(raw_packages) do
      package = tostring(package or "")
      if package ~= "" and not seen[package] then
        seen[package] = true
        packages[#packages + 1] = package
      end
    end
  
    if #packages == 0 then
      local result = {
        status = "noop",
        packages = {},
      }
      notify("No missing R package diagnostics in current buffer", vim.log.levels.INFO)
      if type(install_opts.callback) == "function" then
        install_opts.callback(result, nil)
      end
      return result
    end
  
    local description = install_opts.description
    if description == nil then
      description = description_file_for_buffer(bufnr)
    end
  
    local dry_run = install_opts.dry_run == true
    if not dry_run then
      notify("Installing R packages: " .. table.concat(packages, ", "), vim.log.levels.INFO)
    end
  
    return package_install_request_async(bufnr, packages, description, dry_run, function(result, err)
      if result and not dry_run then
        notify(package_install_message(result), vim.log.levels.INFO)
        Controller.refresh(bufnr)
      end
  
      if type(install_opts.callback) == "function" then
        install_opts.callback(result, err)
      end
    end)
  end
  
  local target_scalar
  
  local function target_records(payload, key)
    if type(payload) ~= "table" then
      return {}
    end
    local value = payload[key]
    if type(value) ~= "table" then
      return {}
    end
    return value
  end
  
  local function target_name(record)
    if type(record) ~= "table" then
      return ""
    end
    return target_scalar(record.name)
  end
  
  target_scalar = function(value)
    if value == nil or value == vim.NIL then
      return ""
    end
    if type(value) == "table" then
      return vim.inspect(value)
    end
    return tostring(value)
  end
  
  local function target_location(record)
    local path = type(record) == "table" and target_scalar(record.path) or ""
    local line = type(record) == "table" and tonumber(record.line) or nil
    if path == "" then
      return ""
    end
    if line and line > 0 then
      return path .. ":" .. line
    end
    return path
  end
  
  local function target_preview_text(record)
    local name = target_name(record)
    if name == "" then
      name = "(unnamed target)"
    end
  
    local location = target_location(record)
    local call = type(record) == "table" and target_scalar(record.call) or ""
    local command = type(record) == "table" and target_scalar(record.command) or ""
    local generator_name = type(record) == "table" and target_scalar(record.generator_name) or ""
    local progress = type(record) == "table" and target_scalar(record.progress) or ""
    local lines = {
      "# " .. name,
      "",
    }
  
    if generator_name ~= "" and generator_name ~= name then
      lines[#lines + 1] = "Derived from: " .. generator_name
      lines[#lines + 1] = ""
    end
  
    if progress ~= "" then
      lines[#lines + 1] = "Progress: " .. progress
      lines[#lines + 1] = ""
    end
  
    if location ~= "" then
      lines[#lines + 1] = "Created in: " .. location
      lines[#lines + 1] = ""
    end
  
    if call ~= "" then
      lines[#lines + 1] = "```r"
      vim.list_extend(lines, vim.split(call, "\n", { plain = true }))
      lines[#lines + 1] = "```"
      lines[#lines + 1] = ""
    end
  
    if command ~= "" then
      lines[#lines + 1] = "Command:"
      lines[#lines + 1] = command
    end
  
    return table.concat(lines, "\n")
  end
  
  local function target_picker_layout()
    return {
      preset = "vertical",
      layout = {
        width = 0.72,
        min_width = 64,
        height = 0.68,
        min_height = 18,
        box = "vertical",
        border = true,
        title = "{title}",
        title_pos = "center",
        { win = "input", height = 1, border = "bottom" },
        { win = "list", title = "Targets", height = 0.38, border = "none" },
        { win = "preview", title = "Created By", height = 0.62, border = "top" },
      },
    }
  end
  
  local function format_target_picker_item(item)
    local command = target_scalar(item.command)
    if command ~= "" then
      return {
        { target_name(item), "Identifier" },
        { "  " },
        { command:gsub("%s+", " "), "Comment" },
      }
    end
    return {
      { target_name(item), "Identifier" },
    }
  end
  
  local function target_picker_items(records)
    local items = {}
    for _, record in ipairs(records) do
      local name = target_name(record)
      local command = target_scalar(record.command)
      local location = target_location(record)
      items[#items + 1] = vim.tbl_extend("force", vim.deepcopy(record), {
        text = table.concat({ name, command, location }, " "),
        preview = {
          text = target_preview_text(record),
          ft = "markdown",
          loc = false,
        },
      })
    end
    return items
  end
  
  local function open_target_picker(records, on_choice)
    local ok, snacks = pcall(require, "snacks")
    if ok and type(snacks) == "table" and type(snacks.picker) == "table" and type(snacks.picker.pick) == "function" then
      snacks.picker.pick({
        title = "Ark Targets",
        items = target_picker_items(records),
        format = format_target_picker_item,
        preview = "preview",
        layout = target_picker_layout(),
        confirm = function(picker, item)
          picker:close()
          on_choice(item)
        end,
      })
      return true
    end
  
    vim.ui.select(records, {
      prompt = "Ark target",
      format_item = function(record)
        local name = target_name(record)
        local command = target_scalar(record.command)
        if command ~= "" then
          return name .. "  " .. command:gsub("%s+", " ")
        end
        return name
      end,
    }, on_choice)
  
    return true
  end
  
  local function target_action_names(result, fallback)
    local value = type(result) == "table" and result.names or nil
    if type(value) ~= "table" or vim.tbl_isempty(value) then
      value = normalize_target_names(fallback)
    end
  
    local names = {}
    if type(value) == "table" then
      for _, name in ipairs(value) do
        local text = target_scalar(name)
        if text ~= "" then
          names[#names + 1] = text
        end
      end
    end
    return names
  end
  
  local function target_action_field_names(result, field)
    local names = {}
    local value = type(result) == "table" and result[field] or nil
    if type(value) ~= "table" then
      return names
    end
  
    for _, name in ipairs(value) do
      local text = target_scalar(name)
      if text ~= "" then
        names[#names + 1] = text
      end
    end
    return names
  end
  
  local function target_names_label(names)
    return #names == 1 and "target" or "targets"
  end
  
  local function target_action_message(action, result, requested_names)
    local names = target_action_names(result, requested_names)
    local rendered_names = table.concat(names, ", ")
    local noun = target_names_label(names)
  
    if action == "invalidate" then
      local invalidated = target_action_field_names(result, "invalidated_names")
      local already_invalidated = target_action_field_names(result, "already_invalidated_names")
      if #invalidated > 0 and #already_invalidated > 0 then
        return "Invalidated "
          .. target_names_label(invalidated)
          .. ": "
          .. table.concat(invalidated, ", ")
          .. "; already invalidated: "
          .. table.concat(already_invalidated, ", ")
      elseif #invalidated > 0 then
        return "Invalidated " .. target_names_label(invalidated) .. ": " .. table.concat(invalidated, ", ")
      elseif #already_invalidated > 0 then
        return "Already invalidated " .. target_names_label(already_invalidated) .. ": " .. table.concat(already_invalidated, ", ")
      end
      return #names > 0 and ("Invalidated " .. noun .. ": " .. rendered_names) or "Invalidated targets"
    elseif action == "load" then
      return #names > 0 and ("Sent tar_load() for " .. noun .. ": " .. rendered_names) or "Sent tar_load()"
    elseif action == "make_downstream" then
      return #names > 0 and ("Built " .. noun .. " and downstream: " .. rendered_names)
        or "Built target and downstream"
    elseif action == "make" then
      return #names > 0 and ("Built " .. noun .. ": " .. rendered_names) or "Built targets"
    end
  
    return "Target action finished"
  end
  
  local target_active_by_root = {}
  
  local function target_active_path(project)
    local root = type(project) == "table" and project.root or vim.loop.cwd()
    local key = vim.fn.sha256(vim.fs.normalize(root or ""))
    return vim.fs.normalize(vim.fn.stdpath("data") .. "/ark/targets/" .. key .. "/active_target.txt")
  end
  
  local function write_active_target(project, name)
    local path = target_active_path(project)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    return pcall(vim.fn.writefile, { name }, path)
  end
  
  local function read_active_target(project)
    local path = target_active_path(project)
    if vim.fn.filereadable(path) ~= 1 then
      return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path, "", 1)
    if not ok or type(lines) ~= "table" then
      return nil
    end
    local name = lines[1]
    if type(name) ~= "string" or name == "" then
      return nil
    end
    return name
  end
  
  local function clear_active_target(project)
    local root = type(project) == "table" and project.root or nil
    if type(root) == "string" and root ~= "" then
      target_active_by_root[root] = nil
    end
  
    local path = target_active_path(project)
    if vim.fn.filereadable(path) == 1 then
      pcall(vim.fn.delete, path)
    end
  end
  
  local function target_manifest_has_name(project, name)
    local payload = target_tools.static_manifest(project)
    for _, record in ipairs(target_records(payload, "targets")) do
      if target_name(record) == name then
        return true
      end
    end
    return false
  end
  
  local function target_project_label(payload)
    local project = type(payload) == "table" and payload.project or nil
    if type(project) == "table" and type(project.root) == "string" and project.root ~= "" then
      return project.root
    end
    return vim.loop.cwd()
  end
  
  local function open_targets_text(title, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, string.format("%s #%d", title, buf))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  
    return { bufnr = buf, lines = lines }
  end
  
  local function render_targets_graph(payload)
    local lines = {
      "# Ark Target Graph",
      "",
      "Project: " .. target_project_label(payload),
      "Source: " .. target_scalar(payload and payload.source),
      "",
    }
  
    local edges = target_records(payload, "edges")
    if #edges == 0 then
      lines[#lines + 1] = "(no graph edges)"
      return lines
    end
  
    lines[#lines + 1] = "From -> To"
    lines[#lines + 1] = "---------"
    for _, edge in ipairs(edges) do
      local from = target_scalar(edge.from)
      local to = target_scalar(edge.to)
      if from ~= "" or to ~= "" then
        lines[#lines + 1] = from .. " -> " .. to
      end
    end
    return lines
  end
  
  local function render_targets_status(payload, title)
    local lines = {
      "# " .. title,
      "",
      "Project: " .. target_project_label(payload),
      "",
    }
  
    local meta = target_records(payload, "meta")
    if #meta == 0 then
      lines[#lines + 1] = "(no target metadata)"
      return lines
    end
  
    for _, row in ipairs(meta) do
      local name = target_scalar(row.name)
      if name == "" then
        name = "(unnamed target)"
      end
      lines[#lines + 1] = "## " .. name
      for _, key in ipairs({ "progress", "time", "seconds", "bytes", "format", "error", "warning", "path" }) do
        local value = target_scalar(row[key])
        if value ~= "" then
          lines[#lines + 1] = "- " .. key .. ": " .. value
        end
      end
      lines[#lines + 1] = ""
    end
  
    return lines
  end
  
  function Controller.targets_project_info(bufnr)
    return targets_request(bufnr, "ark.nvim target project info", function(project, target_bufnr)
      return lsp.targets_project_info(options, target_bufnr, project)
    end)
  end
  
  function Controller.targets_manifest(bufnr)
    return targets_request(bufnr, "ark.nvim target manifest", function(project, target_bufnr)
      return lsp.targets_manifest(options, target_bufnr, project)
    end)
  end
  
  function Controller.targets_set_active(name, bufnr)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
  
    if type(name) ~= "string" or name == "" then
      local err = "missing target name"
      notify(err, vim.log.levels.WARN)
      return nil, err
    end
  
    local project = targets_project(bufnr)
    target_active_by_root[project.root] = name
    local ok, write_err = write_active_target(project, name)
    if not ok then
      notify(write_err or "failed to persist active target", vim.log.levels.WARN)
    end
    return name
  end
  
  function Controller.targets_active(bufnr)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
  
    local project = targets_project(bufnr)
    local name = target_active_by_root[project.root] or read_active_target(project)
    if type(name) ~= "string" or name == "" then
      return nil, "no active target set"
    end
    if not target_manifest_has_name(project, name) then
      clear_active_target(project)
      return nil, "active target no longer exists: " .. name
    end
    target_active_by_root[project.root] = name
    return name
  end
  
  function Controller.targets_pick(bufnr, callback)
    bufnr = resolve_bufnr(bufnr)
    local project = targets_project(bufnr)
    local payload = target_tools.static_manifest(project)
  
    local records = vim.tbl_filter(function(record)
      return target_name(record) ~= ""
    end, target_records(payload, "targets"))
    table.sort(records, function(left, right)
      return target_name(left) < target_name(right)
    end)
  
    if #records == 0 then
      local pick_err = "No static targets found in _targets.R or _target_pipelines."
      notify(pick_err, vim.log.levels.WARN)
      return nil, pick_err
    end
  
    open_target_picker(records, function(record)
      if not record then
        return
      end
      local name = target_name(record)
      if name == "" then
        return
      end
      Controller.targets_set_active(name, bufnr)
      if type(callback) == "function" then
        callback(name, record)
      else
        notify("Active target: " .. name, vim.log.levels.INFO)
      end
    end)
  
    return true
  end
  
  function Controller.targets_view(name, bufnr)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
  
    if type(name) ~= "string" or name == "" then
      local err = "missing target name"
      notify(err, vim.log.levels.WARN)
      return nil, err
    end
  
    local source_bufnr = resolve_view_source_bufnr(bufnr)
    if type(source_bufnr) ~= "number" then
      local err = "ark.nvim target ArkView requires an R-family buffer"
      notify(err, vim.log.levels.WARN)
      return nil, err
    end
  
    local project = targets_project(source_bufnr)
  
    if should_use_tmux_view_popup() then
      local backend = target_view.create({
        name = name,
        project = project,
        source_bufnr = source_bufnr,
        options = options,
        notify = notify,
      })
      local server = current_nvim_server()
      if type(server) == "string" and server ~= "" then
        local backend_id, backend_err = view_popup_backend.register({
          lsp = backend.lsp,
          on_dispose = backend.stop,
          options = options,
          source_bufnr = source_bufnr,
        })
        local view_opts = type(options) == "table" and type(options.view) == "table" and options.view or {}
        if backend_id then
          local popup_opts = vim.tbl_deep_extend("force", view_opts.popup or {}, {
            title = "ArkView: " .. backend.expr,
          })
          local opened, popup_err = session_backend.view_popup(options, server, backend_id, backend.expr, popup_opts)
          if opened then
            return opened
          end
  
          view_popup_backend.unregister(backend_id)
          if normalize_view_display(view_opts.display) == "tmux_popup" then
            local err = popup_err or "failed to open tmux ArkView popup"
            notify(err, vim.log.levels.WARN)
            return nil, err
          end
        else
          backend.stop()
          if normalize_view_display(view_opts.display) == "tmux_popup" then
            local err = backend_err or "failed to register target ArkView popup backend"
            notify(err, vim.log.levels.WARN)
            return nil, err
          end
        end
      else
        backend.stop()
        local view_opts = type(options) == "table" and type(options.view) == "table" and options.view or {}
        if normalize_view_display(view_opts.display) == "tmux_popup" then
          local err = "tmux ArkView popup requires this Neovim instance to have an RPC server"
          notify(err, vim.log.levels.WARN)
          return nil, err
        end
      end
    end
  
    return target_view.open({
      name = name,
      project = project,
      source_bufnr = source_bufnr,
      options = options,
      notify = notify,
    })
  end
  
  function Controller.targets_view_pick(bufnr)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
  
    local source_bufnr = resolve_view_source_bufnr(bufnr)
    if type(source_bufnr) ~= "number" then
      local err = "ark.nvim target ArkView requires an R-family buffer"
      notify(err, vim.log.levels.WARN)
      return nil, err
    end
  
    return Controller.targets_pick(source_bufnr, function(name)
      if type(name) ~= "string" or name == "" then
        return
      end
  
      Controller.targets_view(name, bufnr)
    end)
  end
  
  function Controller.targets_network(bufnr)
    return targets_request(bufnr, "ark.nvim target network", function(project, target_bufnr)
      return lsp.targets_network(options, target_bufnr, project)
    end)
  end
  
  function Controller.targets_graph(bufnr)
    local payload, err = Controller.targets_network(bufnr)
    if not payload then
      return nil, err
    end
    return open_targets_text("Ark Target Graph", render_targets_graph(payload))
  end
  
  function Controller.targets_meta(names, bufnr)
    names = normalize_target_names(names)
    return targets_request(bufnr, "ark.nvim target metadata", function(project, target_bufnr)
      return lsp.targets_meta(options, target_bufnr, project, names)
    end)
  end
  
  function Controller.targets_status(names, bufnr)
    local payload, err = Controller.targets_meta(names, bufnr)
    if not payload then
      return nil, err
    end
    return open_targets_text("Ark Target Status", render_targets_status(payload, "Ark Target Status"))
  end
  
  function Controller.targets_log(names, bufnr)
    local payload, err = Controller.targets_meta(names, bufnr)
    if not payload then
      return nil, err
    end
    return open_targets_text("Ark Target Log", render_targets_status(payload, "Ark Target Log"))
  end
  
  function Controller.targets_object_meta(name, bufnr)
    return targets_request(bufnr, "ark.nvim target object metadata", function(project, target_bufnr)
      return lsp.targets_object_meta(options, target_bufnr, project, name)
    end)
  end
  
  function Controller.targets_load(names, bufnr)
    ensure_setup()
    bufnr = resolve_bufnr(bufnr)
    names = normalize_target_names(names)
  
    local expr = target_load_expression(names)
    local ok, err = Controller.send(expr)
    if not ok then
      return nil, err
    end
  
    return {
      status = "sent",
      action = "load",
      names = names,
      expression = expr,
    }
  end
  
  function Controller.targets_action(action, names, bufnr)
    names = normalize_target_names(names)
    if action == "load" then
      return Controller.targets_load(names, bufnr)
    end
  
    return targets_request(bufnr, "ark.nvim target action", function(project, target_bufnr)
      return lsp.targets_action(options, target_bufnr, project, action, names)
    end)
  end
  
  function Controller.targets_action_user(action, names, bufnr)
    names = normalize_target_names(names)
    if action == "load" then
      local result, err = Controller.targets_load(names, bufnr)
      if result then
        notify(target_action_message(action, result, names), vim.log.levels.INFO)
      end
      return result, err
    end
  
    return targets_request_async(bufnr, "ark.nvim target action", function(project, target_bufnr, callback)
      return lsp.targets_action_async(options, target_bufnr, project, action, names, callback)
    end, function(result)
      if result then
        notify(target_action_message(action, result, names), vim.log.levels.INFO)
      end
    end)
  end
  
  function Controller.targets_action_pick(action, bufnr)
    return Controller.targets_pick(bufnr, function(name)
      Controller.targets_action_user(action, name, bufnr)
    end)
  end
  
  function Controller.targets_action_active(action, bufnr)
    local name, err = Controller.targets_active(bufnr)
    if not name then
      notify(err or "no active target set", vim.log.levels.WARN)
      return nil, err
    end
    return Controller.targets_action(action, name, bufnr)
  end

  Controller.tar_read_target_name = tar_read_target_name
  return Controller
end

return M
