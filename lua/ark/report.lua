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
