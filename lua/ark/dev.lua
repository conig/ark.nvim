local uv = vim.uv or vim.loop

local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local ROOT = repo_root()
local BUILD_CMD = { "cargo", "build", "-p", "ark", "--bin", "ark-lsp" }
local checked = {}

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local function stat_mtime(path)
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  return stat and stat.mtime and stat.mtime.sec or nil
end

local function repo_target_binary(path)
  local normalized = normalize_path(path)
  if not normalized then
    return nil
  end

  if not vim.startswith(normalized, ROOT .. "/target/") then
    return nil
  end

  return normalized
end

local function rust_source_paths()
  local paths = {}

  if vim.fn.executable("rg") == 1 then
    paths = vim.fn.systemlist({
      "rg",
      "--files",
      ROOT .. "/crates/ark/src",
      ROOT .. "/crates/ark_test/src",
    })
    if vim.v.shell_error ~= 0 then
      paths = {}
    end
  end

  paths[#paths + 1] = ROOT .. "/crates/ark/Cargo.toml"
  paths[#paths + 1] = ROOT .. "/crates/ark_test/Cargo.toml"
  paths[#paths + 1] = ROOT .. "/Cargo.lock"

  return paths
end

local function newest_source_mtime()
  local newest_mtime = 0
  local newest_path = nil

  for _, path in ipairs(rust_source_paths()) do
    local mtime = stat_mtime(path)
    if type(mtime) == "number" and mtime > newest_mtime then
      newest_mtime = mtime
      newest_path = path
    end
  end

  return newest_mtime, newest_path
end

local function run_build()
  if vim.fn.executable("cargo") ~= 1 then
    return false, "`cargo` is not available to rebuild `ark-lsp`"
  end

  if not vim.system then
    return false, "this Neovim does not support `vim.system()`, so automatic `ark-lsp` rebuild is unavailable"
  end

  vim.notify("Rebuilding stale detached ark-lsp binary", vim.log.levels.INFO, { title = "ark.nvim" })

  local result = vim.system(BUILD_CMD, {
    cwd = ROOT,
    text = true,
  }):wait()

  if result.code ~= 0 then
    local output = table.concat({
      result.stdout or "",
      result.stderr or "",
    }, "")
    output = vim.trim(output)
    if output == "" then
      output = "unknown cargo build failure"
    end
    return false, output
  end

  return true, nil
end

function M.ensure_current_detached_lsp_cmd(cmd)
  if type(cmd) ~= "table" or type(cmd[1]) ~= "string" or cmd[1] == "" then
    return cmd, nil
  end

  local binary_path = repo_target_binary(cmd[1])
  if not binary_path then
    return cmd, nil
  end

  local newest_mtime, newest_path = newest_source_mtime()
  local binary_mtime = stat_mtime(binary_path) or 0
  local cache_key = table.concat({
    binary_path,
    tostring(binary_mtime),
    tostring(newest_mtime),
  }, "::")

  if checked[cache_key] then
    local updated = vim.deepcopy(cmd)
    updated[1] = binary_path
    return updated, nil
  end

  if binary_mtime == 0 or (type(newest_mtime) == "number" and newest_mtime > binary_mtime) then
    local ok, build_err = run_build()
    if not ok then
      return nil, string.format(
        "detached ark-lsp binary is stale relative to %s and rebuild failed: %s",
        newest_path or "Rust sources",
        build_err
      )
    end

    binary_mtime = stat_mtime(binary_path) or 0
    if binary_mtime == 0 then
      return nil, "cargo reported success, but detached ark-lsp binary is still missing: " .. binary_path
    end
  end

  checked[table.concat({
    binary_path,
    tostring(binary_mtime),
    tostring(newest_mtime),
  }, "::")] = true

  local updated = vim.deepcopy(cmd)
  updated[1] = binary_path
  return updated, nil
end

function M.build_detached_lsp()
  local ok, build_err = run_build()
  if not ok then
    return nil, build_err
  end

  local binary_path = ROOT .. "/target/debug/ark-lsp"
  if not stat_mtime(binary_path) then
    return nil, "cargo reported success, but detached ark-lsp binary is still missing: " .. binary_path
  end

  return binary_path, nil
end

return M
