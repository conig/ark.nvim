local M = {}

local manifest_cache = nil

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, string.format("could not read release manifest at %s: %s", path, lines)
  end

  local decoded_ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(value) ~= "table" then
    return nil, string.format("could not parse release manifest at %s: %s", path, value)
  end
  return value
end

function M.manifest()
  if manifest_cache then
    return manifest_cache
  end

  local manifest, err = read_json(repo_root() .. "/release-manifest.json")
  if not manifest then
    return nil, err
  end
  if type(manifest.product_version) ~= "string" or manifest.product_version == "" then
    return nil, "release manifest does not define product_version"
  end
  if type(manifest.release_targets) ~= "table" or #manifest.release_targets == 0 then
    return nil, "release manifest does not define any release targets"
  end

  manifest_cache = manifest
  return manifest_cache
end

function M.product_version()
  local manifest, err = M.manifest()
  if not manifest then
    return nil, err
  end
  return manifest.product_version
end

function M.install_root()
  local override = vim.env.ARK_NVIM_INSTALL_ROOT
  if type(override) == "string" and override ~= "" then
    return vim.fs.normalize(vim.fn.expand(override))
  end
  return vim.fs.normalize(vim.fn.stdpath("data") .. "/ark")
end

function M.installed_binary()
  local path = M.install_root() .. "/current/ark-lsp"
  if vim.fn.executable(path) == 1 then
    return path
  end
  return nil
end

local function normalize_uname(uname)
  uname = uname or (vim.uv or vim.loop).os_uname()
  return {
    os = uname.sysname or uname.sys_name,
    arch = uname.machine,
  }
end

function M.release_target(uname)
  local manifest, err = M.manifest()
  if not manifest then
    return nil, err
  end

  local identity = normalize_uname(uname)
  for _, target in ipairs(manifest.release_targets) do
    if target.os == identity.os and target.arch == identity.arch then
      return target
    end
  end

  return nil, string.format(
    "Ark does not publish a release artifact for %s %s; use the documented source-build fallback",
    tostring(identity.os),
    tostring(identity.arch)
  )
end

local function release_base_url(manifest)
  local override = vim.env.ARK_NVIM_RELEASE_BASE_URL
  if type(override) == "string" and override ~= "" then
    return override:gsub("/+$", "")
  end
  return string.format(
    "https://github.com/%s/releases/download/%s",
    manifest.repository,
    manifest.release_tag
  )
end

function M.install_command()
  local manifest, manifest_err = M.manifest()
  if not manifest then
    return nil, manifest_err
  end
  local target, target_err = M.release_target()
  if not target then
    return nil, target_err
  end

  local base_url = release_base_url(manifest)
  return {
    repo_root() .. "/scripts/install-release.sh",
    "install",
    "--version",
    manifest.product_version,
    "--target",
    target.rust_target,
    "--bridge-schema",
    manifest.compatibility.bridge_schema,
    "--asset-url",
    base_url .. "/" .. target.asset,
    "--checksum-url",
    base_url .. "/" .. target.checksum_asset,
    "--install-root",
    M.install_root(),
  }
end

function M.rollback_command()
  local manifest, manifest_err = M.manifest()
  if not manifest then
    return nil, manifest_err
  end
  local target, target_err = M.release_target()
  if not target then
    return nil, target_err
  end

  return {
    repo_root() .. "/scripts/install-release.sh",
    "rollback",
    "--version",
    manifest.product_version,
    "--target",
    target.rust_target,
    "--bridge-schema",
    manifest.compatibility.bridge_schema,
    "--install-root",
    M.install_root(),
  }
end

local function metadata_matches_release(metadata, manifest, target)
  return type(metadata) == "table"
    and type(manifest) == "table"
    and type(manifest.compatibility) == "table"
    and type(target) == "table"
    and metadata.component == "ark-lsp"
    and metadata.product_version == manifest.product_version
    and metadata.bridge_schema == manifest.compatibility.bridge_schema
    and metadata.target == target.rust_target
    and metadata.profile == "release"
end

local function run(command, action, callback)
  if type(vim.system) ~= "function" then
    local message = "Ark release management requires Neovim with vim.system() support"
    if callback then
      callback(false, message)
    end
    return nil, message
  end

  return vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      local output = vim.trim((result.stdout or "") .. (result.stderr or ""))
      if result.code == 0 then
        vim.notify(output ~= "" and output or (action .. " completed"), vim.log.levels.INFO, {
          title = "ark.nvim",
        })
        if callback then
          callback(true, output)
        end
      else
        local message = output ~= "" and output or string.format("%s failed with exit %d", action, result.code)
        vim.notify(message, vim.log.levels.ERROR, { title = "ark.nvim" })
        if callback then
          callback(false, message)
        end
      end
    end)
  end)
end

function M.install(callback)
  local manifest = M.manifest()
  local target = M.release_target()
  local installed = M.binary_metadata()
  if metadata_matches_release(installed, manifest, target) then
    local message = "Ark release " .. manifest.product_version .. " is already installed"
    vim.notify(message, vim.log.levels.INFO, { title = "ark.nvim" })
    if callback then
      callback(true, message)
    end
    return true
  end

  local command, err = M.install_command()
  if not command then
    vim.notify(err, vim.log.levels.ERROR, { title = "ark.nvim" })
    if callback then
      callback(false, err)
    end
    return nil, err
  end
  return run(command, "Ark install", callback)
end

function M.install_sync()
  local manifest, manifest_err = M.manifest()
  if not manifest then
    return false, manifest_err
  end
  local installed = M.binary_metadata()
  local target = M.release_target()
  if metadata_matches_release(installed, manifest, target) then
    return true, "Ark release " .. manifest.product_version .. " is already installed"
  end

  local command, command_err = M.install_command()
  if not command then
    return false, command_err
  end
  local output = vim.fn.system(command)
  if vim.v.shell_error ~= 0 then
    return false, vim.trim(output)
  end
  return true, vim.trim(output)
end

function M.rollback(callback)
  local command, err = M.rollback_command()
  if not command then
    vim.notify(err, vim.log.levels.ERROR, { title = "ark.nvim" })
    if callback then
      callback(false, err)
    end
    return nil, err
  end
  return run(command, "Ark rollback", callback)
end

function M.binary_metadata(path)
  path = path or M.installed_binary()
  if type(path) ~= "string" or path == "" or vim.fn.executable(path) ~= 1 then
    return nil, "ark-lsp is not installed"
  end

  local output = vim.fn.system({ path, "--version", "--json" })
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(output)
  end
  local ok, metadata = pcall(vim.json.decode, output)
  if not ok or type(metadata) ~= "table" then
    return nil, "ark-lsp returned invalid version metadata"
  end
  return metadata
end

function M.status()
  local manifest, manifest_err = M.manifest()
  local installed = M.installed_binary()
  local metadata, metadata_err = M.binary_metadata(installed)
  return {
    product_version = manifest and manifest.product_version or nil,
    release_tag = manifest and manifest.release_tag or nil,
    release_channel = manifest and manifest.release_channel or nil,
    compatibility = manifest and manifest.compatibility or nil,
    supported_environment = manifest and manifest.supported_environment or nil,
    manifest_error = manifest_err,
    install_root = M.install_root(),
    installed_binary = installed,
    installed_metadata = metadata,
    installed_metadata_error = metadata_err,
  }
end

return M
