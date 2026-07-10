local errors = require("ark.errors")

for _, code in ipairs({
  "E_CONFIG",
  "E_INSTALL",
  "E_LSP_UNAVAILABLE",
  "E_BACKEND_UNAVAILABLE",
  "E_BRIDGE_MISSING",
  "E_BRIDGE_INCOMPATIBLE",
  "E_IPC_AUTH",
  "E_IPC_REQUEST",
  "E_IPC_DECODE",
  "E_IPC_HANDLER",
  "E_IPC_BOOTSTRAP",
  "E_IPC_HELP",
  "E_IPC_PACKAGE_INFO",
  "E_IPC_PACKAGE_INSTALL",
  "E_IPC_VIEW",
  "E_IPC_VIEW_GONE",
  "E_IPC_VIEW_TYPE",
  "E_IPC_TARGETS",
  "E_TARGET_VIEW",
  "E_EVAL",
}) do
  local entry = errors.lookup(code)
  assert(type(entry.state) == "string" and entry.state ~= "", code)
  assert(type(entry.action) == "string" and entry.action ~= "", code)
  local rendered = errors.format(code, "failure")
  assert(rendered:find("[" .. code .. "]", 1, true), rendered)
  assert(rendered:find("Recovery:", 1, true), rendered)
end

assert(errors.lookup("E_UNKNOWN").action:find(":Ark report", 1, true))
