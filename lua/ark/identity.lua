-- Installation identity and asynchronous source snapshots. No Git/network/Cargo
-- invocation on the unchanged path; content hashing runs in the native worker.
local M = {}
local uv = vim.uv
local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local snapshots = {}
local states = {}
local plugin_fingerprint
local plugin_warned

function M.source_checkout()
  return uv.fs_stat(ROOT .. "/Cargo.toml") ~= nil
    and uv.fs_stat(ROOT .. "/crates/ark-lsp/Cargo.toml") ~= nil
end

function M.origin(binary)
  local path = vim.fn.exepath(binary)
  if path == "" then path = vim.fn.fnamemodify(binary, ":p") end
  path = vim.fs.normalize(path)
  if M.source_checkout() and (path == ROOT .. "/target/debug/ark-lsp" or path == ROOT .. "/target/release/ark-lsp") then
    return "source", path
  end
  local installed = require("ark.release").installed_binary()
  if installed and path == vim.fs.normalize(installed) then return "release", path end
  return "external", path
end

function M.signature(stat)
  if not stat then return "missing" end
  return table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ":")
end

function M.binary_signature(path)
  local resolved = vim.fn.exepath(path)
  return M.signature(uv.fs_stat(resolved ~= "" and resolved or path))
end

function M.state(binary, changes)
  local state = states[binary] or { origin = M.origin(binary), binary = binary, phase = "unchecked" }
  states[binary] = state
  if changes then for key, value in pairs(changes) do state[key] = value end end
  return vim.deepcopy(state)
end

local function unchanged(inputs, callback)
  local next_index, active, completed = 1, 0, 0
  local same = true
  local launch
  launch = function()
    while active < 32 and next_index <= #inputs do
      local entry = inputs[next_index]
      next_index, active = next_index + 1, active + 1
      uv.fs_stat(entry.path, function(_, stat)
        same = same and M.signature(stat) == entry.signature
        active, completed = active - 1, completed + 1
        if completed == #inputs then vim.schedule(function() callback(same) end) else launch() end
      end)
    end
  end
  if #inputs == 0 then callback(false) else launch() end
end

function M.snapshot(binary, component, callback, force)
  local key = binary .. ":" .. component
  local cache = snapshots[key] or { listeners = {} }
  snapshots[key] = cache
  cache.listeners[#cache.listeners + 1] = callback
  if cache.running then return end
  cache.running = true
  local signature = M.binary_signature(binary)
  local function finish(value, err)
    cache.running = false
    if value then cache.value, cache.signature = value, signature end
    local listeners = cache.listeners
    cache.listeners = {}
    for _, listener in ipairs(listeners) do listener(value, err) end
  end
  local function probe()
    local ok, err = pcall(vim.system, { binary, "--source-identity", ROOT, component }, { text = true }, function(result)
      vim.schedule(function()
        local decoded, value = pcall(vim.json.decode, result.stdout or "")
        if result.code ~= 0 or not decoded or type(value) ~= "table" or type(value.fingerprint) ~= "string"
          or type(value.inputs) ~= "table" or type(value.built) ~= "table" then
          finish(nil, "binary has no usable source identity; rebuild required")
        else finish(value) end
      end)
    end)
    if not ok then finish(nil, tostring(err)) end
  end
  if not force and cache.value and cache.signature == signature then
    unchanged(cache.value.inputs, function(same)
      if same then finish(cache.value) else probe() end
    end)
  else probe() end
end

function M.verify_external(binary, on_change)
  local signature = M.binary_signature(binary)
  local state = M.state(binary)
  if state.signature == signature then return end
  M.state(binary, { signature = signature, phase = "checking" })
  local function compatible(metadata)
    M.state(binary, { phase = "compatible", installed = metadata })
    if metadata.build_id and state.running and state.running.build_id ~= metadata.build_id then
      M.state(binary, { phase = "restarting", expected = metadata.source_fingerprint,
        expected_build_id = metadata.build_id, announce_activation = true })
      if on_change then on_change({ ok = true, binary_path = binary }) end
    end
  end
  local started, start_err = pcall(vim.system, { binary, "--version", "--json" }, { text = true }, function(result)
    vim.schedule(function()
      local ok, metadata = pcall(vim.json.decode, result.stdout or "")
      local manifest = require("ark.release").manifest()
      if result.code ~= 0 or not ok or type(metadata) ~= "table" or not manifest
        or metadata.component ~= "ark-lsp"
        or metadata.bridge_schema ~= manifest.compatibility.bridge_schema
        or metadata.product_version ~= manifest.product_version then
        M.state(binary, { phase = "incompatible" })
        vim.notify("Ark binary does not match this plugin installation: " .. binary
          .. ". Select a matching binary or use :Ark install; external binaries are never overwritten.", vim.log.levels.WARN)
      elseif M.source_checkout() then
        M.snapshot(binary, "lsp", function(snapshot)
          if not snapshot or snapshot.fingerprint ~= metadata.source_fingerprint then
            M.state(binary, { phase = "mismatch", installed = metadata })
            vim.notify("The explicitly selected Ark binary does not match this checkout; it was not overwritten: " .. binary, vim.log.levels.WARN)
          else compatible(metadata) end
        end)
      else compatible(metadata) end
    end)
  end)
  if not started then
    M.state(binary, { phase = "unavailable", error = tostring(start_err) })
    vim.notify("Cannot verify selected Ark binary: " .. tostring(start_err), vim.log.levels.WARN)
  end
end

function M.check_plugin(binary)
  if not M.source_checkout() then return end
  M.snapshot(binary, "plugin", function(snapshot)
    if not snapshot then return end
    if not plugin_fingerprint then plugin_fingerprint = snapshot.fingerprint; return end
    if snapshot.fingerprint ~= plugin_fingerprint and plugin_warned ~= snapshot.fingerprint then
      plugin_warned = snapshot.fingerprint
      M.state(binary, { plugin_restart_required = true })
      vim.notify("Ark editor/terminal integration changed; restart Neovim to load it. R was not restarted.", vim.log.levels.WARN)
    end
  end)
end

function M.activated(binary, client)
  local build = ((client.server_capabilities or {}).experimental or {}).arkBuild
  M.check_plugin(binary)
  local state = M.state(binary)
  M.state(binary, { running = build or {}, client_id = client.id })
  if state.expected and (not build or build.source_fingerprint ~= state.expected
    or (state.expected_build_id and build.build_id ~= state.expected_build_id)) then
    M.state(binary, { phase = "mismatch" })
    vim.notify("Ark is still running an older LSP build; update activation could not be verified.", vim.log.levels.ERROR)
  elseif state.expected then
    M.state(binary, { phase = "current" })
    if state.announce_activation then
      M.state(binary, { announce_activation = false })
      vim.notify("Ark LSP updated and active", vim.log.levels.INFO)
    end
  end
end

return M
