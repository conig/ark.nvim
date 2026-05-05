local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local function r_string(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\")
  value = value:gsub('"', '\\"')
  return '"' .. value .. '"'
end

local function normalize_path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local run_tmpdir = ark_test.run_tmpdir()
local session_lib = normalize_path(run_tmpdir .. "/ark-session-lib")
local user_lib = normalize_path(run_tmpdir .. "/r-user-lib")
local probe_file = normalize_path(run_tmpdir .. "/libpaths.txt")
local test_file = normalize_path(run_tmpdir .. "/launcher_restores_user_libpaths.R")
local empty_profile = normalize_path(run_tmpdir .. "/empty.Rprofile")
local wrapper = normalize_path(run_tmpdir .. "/ark-r-launcher-wrapper.sh")
local launcher = normalize_path(vim.fn.getcwd() .. "/scripts/ark-r-launcher.sh")

vim.fn.mkdir(session_lib, "p")
vim.fn.mkdir(user_lib, "p")
vim.fn.writefile({}, empty_profile)

vim.fn.writefile({
  "#!/usr/bin/env sh",
  "R_PROFILE_USER=" .. vim.fn.shellescape(empty_profile)
    .. " R_LIBS_USER=" .. vim.fn.shellescape(user_lib)
    .. " exec "
    .. vim.fn.shellescape(launcher)
    .. ' "$@"',
}, wrapper)
vim.fn.setfperm(wrapper, "rwxr-xr-x")

local pane_id = ark_test.setup_managed_buffer(test_file, {
  "x <- 1",
}, {
  tmux = {
    launcher = wrapper,
    session_lib_path = session_lib,
  },
})

-- The launcher may temporarily prepend Ark's private library while loading the
-- bridge, but the interactive REPL must see the user's normal library paths.
ark_test.tmux({
  "send-keys",
  "-l",
  "-t",
  pane_id,
  "writeLines(.libPaths(), " .. r_string(probe_file) .. ")",
})
ark_test.tmux({ "send-keys", "-t", pane_id, "Enter" })

ark_test.wait_for("REPL .libPaths() probe", 10000, function()
  return vim.fn.filereadable(probe_file) == 1
end)

local libpaths = vim.tbl_map(normalize_path, vim.fn.readfile(probe_file))
if #libpaths == 0 then
  ark_test.fail("REPL .libPaths() probe wrote no paths")
end

for _, path in ipairs(libpaths) do
  if path == session_lib then
    ark_test.fail("Ark session lib leaked into user-facing REPL .libPaths(): " .. vim.inspect({
      session_lib = session_lib,
      libpaths = libpaths,
      status = require("ark").status({ include_lsp = true }),
    }))
  end
end

local status = require("ark").status({ include_lsp = true })
if status.bridge_ready ~= true or status.repl_ready ~= true then
  ark_test.fail("expected bridge and REPL to remain ready after restoring .libPaths(): " .. vim.inspect(status))
end

vim.print({
  libpaths = libpaths,
  session_lib = session_lib,
  status = status,
})
