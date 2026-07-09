vim.opt.rtp:prepend(vim.fn.getcwd())

local original_install_root = vim.env.ARK_NVIM_INSTALL_ROOT
local original_lsp_bin = vim.env.ARK_NVIM_LSP_BIN
local original_dev_mode = vim.env.ARK_NVIM_DEV_MODE
local original_release_base_url = vim.env.ARK_NVIM_RELEASE_BASE_URL
local temp_root = vim.fn.tempname()
local installed_binary = temp_root .. "/current/ark-lsp"
local override_binary = temp_root .. "/override-ark-lsp"
local debug_binary = vim.fs.normalize(vim.fn.getcwd() .. "/target/debug/ark-lsp")
local debug_binary_existed = vim.fn.executable(debug_binary) == 1

local function write_fake_binary(path, version)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({
    "#!/bin/sh",
    "printf '%s\\n' '" .. vim.json.encode({
      component = "ark-lsp",
      product_version = version,
      bridge_schema = "v1",
      crate_version = "0.1.251",
      commit = "fixture",
      target = "x86_64-unknown-linux-gnu",
      profile = "release",
      rustc = "fixture",
    }) .. "'",
  }, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
end

vim.env.ARK_NVIM_INSTALL_ROOT = temp_root
vim.env.ARK_NVIM_LSP_BIN = nil
vim.env.ARK_NVIM_DEV_MODE = nil

local ok, err = xpcall(function()
  package.loaded["ark.release"] = nil
  package.loaded["ark.config"] = nil
  local release = require("ark.release")
  local manifest = assert(release.manifest())

  if manifest.product_version ~= "0.1.0-alpha.1" then
    error("unexpected product version: " .. vim.inspect(manifest.product_version), 0)
  end

  local target = assert(release.release_target({ sysname = "Linux", machine = "x86_64" }))
  if target.rust_target ~= "x86_64-unknown-linux-gnu" then
    error("unexpected Linux release target: " .. vim.inspect(target), 0)
  end
  local unsupported, unsupported_err = release.release_target({ sysname = "Darwin", machine = "arm64" })
  if unsupported ~= nil or not tostring(unsupported_err):find("source%-build fallback") then
    error("unsupported target should return an actionable source-build error", 0)
  end

  write_fake_binary(installed_binary, manifest.product_version)
  local metadata = assert(release.binary_metadata())
  if metadata.product_version ~= manifest.product_version or metadata.profile ~= "release" then
    error("installed release metadata was not parsed correctly: " .. vim.inspect(metadata), 0)
  end

  package.loaded["ark.config"] = nil
  local defaults = require("ark.config").defaults()
  if defaults.lsp.cmd[1] ~= installed_binary then
    error("packaged release should win normal binary discovery: " .. vim.inspect(defaults.lsp.cmd), 0)
  end
  if defaults.development_mode ~= false then
    error("development mode should be disabled by default", 0)
  end

  vim.env.ARK_NVIM_DEV_MODE = "1"
  if not debug_binary_existed then
    write_fake_binary(debug_binary, manifest.product_version)
  end
  package.loaded["ark.config"] = nil
  defaults = require("ark.config").defaults()
  if defaults.lsp.cmd[1] ~= debug_binary then
    error("explicit development mode should prefer the repo debug binary: " .. vim.inspect(defaults.lsp.cmd), 0)
  end
  if defaults.development_mode ~= true then
    error("development mode was not exposed in resolved config", 0)
  end

  write_fake_binary(override_binary, manifest.product_version)
  vim.env.ARK_NVIM_LSP_BIN = override_binary
  package.loaded["ark.config"] = nil
  defaults = require("ark.config").defaults()
  if defaults.lsp.cmd[1] ~= override_binary then
    error("explicit ARK_NVIM_LSP_BIN must override every discovery source", 0)
  end

  vim.env.ARK_NVIM_RELEASE_BASE_URL = "https://example.invalid/releases/test"
  local command = assert(release.install_command())
  local rendered = table.concat(command, " ")
  if not rendered:find(target.asset, 1, true) or not rendered:find(target.checksum_asset, 1, true) then
    error("install command did not select the manifest target assets: " .. rendered, 0)
  end
end, debug.traceback)

vim.env.ARK_NVIM_INSTALL_ROOT = original_install_root
vim.env.ARK_NVIM_LSP_BIN = original_lsp_bin
vim.env.ARK_NVIM_DEV_MODE = original_dev_mode
vim.env.ARK_NVIM_RELEASE_BASE_URL = original_release_base_url
vim.fn.delete(temp_root, "rf")
if not debug_binary_existed then
  vim.fn.delete(debug_binary)
end

if not ok then
  error(err, 0)
end
