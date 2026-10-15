local health = require("ark.health")
local release = require("ark.release")

local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function replacements()
  local values = {
    { vim.fn.stdpath("state"), "<NVIM_STATE>" },
    { vim.fn.stdpath("data"), "<NVIM_DATA>" },
    { repo_root(), "<ARK_ROOT>" },
    { vim.uv.os_homedir(), "<HOME>" },
  }
  table.sort(values, function(lhs, rhs)
    return #(lhs[1] or "") > #(rhs[1] or "")
  end)
  return values
end

function M.redact(value)
  local text = tostring(value or "")
  for _, replacement in ipairs(replacements()) do
    local path, label = replacement[1], replacement[2]
    if type(path) == "string" and path ~= "" then
      text = text:gsub(vim.pesc(vim.fs.normalize(path)), label)
      text = text:gsub(vim.pesc(path), label)
    end
  end
  text = text:gsub("([Aa]uth[_ %-]?[Tt]oken%s*[=:]%s*)[^%s,;}]+", "%1<REDACTED>")
  text = text:gsub("([%w_%-]*[Tt]oken%s*[=:]%s*)[^%s,;}]+", "%1<REDACTED>")
  text = text:gsub("([%w_%-]*[Cc]ookie%s*[=:]%s*)[^%s,;}]+", "%1<REDACTED>")
  text = text:gsub("([Bb]earer%s+)[^%s,;}]+", "%1<REDACTED>")
  text = text:gsub("%f[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]%f[%X]", "<REDACTED-HEX>")
  return text
end

local function bool(value)
  return value == true and "yes" or "no"
end

local function status_lines(status)
  status = status or {}
  local lsp = status.lsp_status or {}
  local startup = status.startup or {}
  local bridge = status.startup_status or {}
  return {
    "- Product state: `" .. tostring(status.product_state or "unconfigured") .. "`",
    "- Configured: " .. bool(status.configured ~= false),
    "- Backend: `" .. tostring(status.backend or "unknown") .. "`",
    "- Bridge ready: " .. bool(status.bridge_ready),
    "- REPL ready: " .. bool(status.repl_ready),
    "- Startup phase: `" .. tostring(startup.phase or "unknown") .. "`",
    "- LSP available: " .. bool(lsp.available),
    "- LSP runtime mode: `" .. tostring(lsp.runtimeMode or "unknown") .. "`",
    "- Bridge product version: `" .. tostring(bridge.product_version or "unavailable") .. "`",
    "- Bridge schema: `" .. tostring(bridge.bridge_schema or "unavailable") .. "`",
  }
end

-- Strict allowlists, not string sanitization: even a plausible identifier can
-- be a private object name. No expressions, request IDs, errors or cell values.
local function label(value, allowed)
  return allowed[value] and value or "other"
end

local operations = {}
for _, name in ipairs({ "inspect", "bootstrap", "help_text", "package_info", "package_install", "view_open", "view_state", "view_page", "view_values", "view_filter", "view_sort", "view_profile", "view_cell", "view_export", "view_close", "targets_manifest", "targets_network", "targets_meta", "targets_action", "error_traceback" }) do
  operations[name] = true
end
local stages = { connect = true, write_request = true, wait_first_byte = true, read_response = true, decode_response = true, serialize_request = true }
local activities = { user_code = true, ark_request = true, ready = true, unresponsive = true, disconnected = true, unavailable = true }

local function number(value)
  return type(value) == "number" and value >= 0 and value < math.huge and string.format("%.1f", value) or "unknown"
end

local function runtime_lines(status)
  status = status or {}
  local activity = type(status.runtime_activity) == "table" and status.runtime_activity or {}
  local lsp = type(status.lsp_status) == "table" and status.lsp_status or {}
  local bridge = type(lsp.sessionBridge) == "table" and lsp.sessionBridge or {}
  local runtime = type(bridge.runtime) == "table" and bridge.runtime or {}
  local lines = { "", "## Recent runtime evidence", "", "- Activity: `" .. label(activity.kind, activities) .. "`" }
  local active = runtime.activeOperation
  if type(active) == "table" then
    lines[#lines + 1] = "- Active: `" .. label(active.operation, operations) .. "`, age=" .. number(active.ageMs) .. "ms"
  end
  local recent = type(runtime.recentRequests) == "table" and runtime.recentRequests or {}
  for index = math.max(1, #recent - 7), #recent do
    local request = recent[index]
    if type(request) == "table" then
      local exchange = type(request.exchange) == "table" and request.exchange or {}
      lines[#lines + 1] = string.format("- `%s`: %s; queue=%sms, total=%sms, stage=%s, response=%s bytes",
        label(request.operation, operations), request.success == true and "completed" or "failed",
        number(request.queueMs), number(request.totalMs), label(exchange.stage, stages), number(exchange.responseBytes))
      local handler = exchange.handler
      if type(handler) == "table" then
        lines[#lines + 1] = string.format("  - Values: rows=%s, distinct=%s, returned=%s, cache=%s; keys=%sms, counts=%sms, labels=%sms",
          number(handler.rows), number(handler.distinct), number(handler.returned), bool(handler.cache_hit),
          number(handler.keys_ms), number(handler.count_ms), number(handler.labels_ms))
      end
    end
  end
  return lines
end

function M.generate(opts)
  opts = opts or {}
  local status = opts.status
  if status == nil then
    local ark = package.loaded["ark"]
    if type(ark) == "table" and type(ark.support_status) == "function" then
      status = ark.support_status()
    else
      status = { configured = false, product_state = "static_only" }
    end
  end
  local release_status = opts.release_status or release.status()
  local compatibility = release_status.compatibility or {}
  local checks = opts.health_checks or health.collect()
  local uname = (vim.uv or vim.loop).os_uname()
  local version = vim.version()

  local lines = {
    "# Ark support report",
    "",
    "> Preview this report before sharing it. Ark omits source text, R object values, arbitrary environment values, auth tokens, and unrelated system logs.",
    "",
    "## Components",
    "",
    "- Product version: `" .. tostring(release_status.product_version or "unknown") .. "`",
    "- Installed LSP version: `" .. tostring(release_status.installed_metadata and release_status.installed_metadata.product_version or "unavailable") .. "`",
    "- Installed LSP profile: `" .. tostring(release_status.installed_metadata and release_status.installed_metadata.profile or "unavailable") .. "`",
    "- Plugin API: `" .. tostring(compatibility.plugin_api or "unknown") .. "`",
    "- LSP API: `" .. tostring(compatibility.lsp_api or "unknown") .. "`",
    "- Expected bridge schema: `" .. tostring(compatibility.bridge_schema or "unknown") .. "`",
    "- Neovim: `" .. string.format("%d.%d.%d", version.major, version.minor, version.patch) .. "`",
    "- Platform: `" .. tostring(uname.sysname or uname.sys_name or "unknown") .. " " .. tostring(uname.machine or "unknown") .. "`",
    "",
    "## Runtime state",
    "",
  }
  vim.list_extend(lines, status_lines(status))
  vim.list_extend(lines, runtime_lines(status))
  vim.list_extend(lines, { "", "## Read-only health checks", "" })
  for _, check in ipairs(checks) do
    if check.kind ~= "start" then
      lines[#lines + 1] = string.format("- **%s**: %s", check.kind, M.redact(check.message))
    end
  end
  vim.list_extend(lines, {
    "",
    "## Diagnostic locations",
    "",
    "- Ark state: `<NVIM_STATE>/ark-status`",
    "- Managed install: `<NVIM_DATA>/ark`",
    "- No log contents are embedded; inspect only the session-specific path shown by `:Ark status`.",
  })
  return vim.tbl_map(M.redact, lines)
end

function M.open(opts)
  local lines = M.generate(opts)
  local buf = vim.fn.bufnr("ark://support-report")
  if buf < 0 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "ark://support-report")
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.api.nvim_set_current_buf(buf)
  return buf
end

return M
