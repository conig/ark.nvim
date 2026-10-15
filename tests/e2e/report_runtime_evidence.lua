local report = require("ark.report")
local records = {}
for i = 1, 30 do
  records[i] = {
    operation = i == 30 and "secret-object-name" or "view_values",
    requestId = "secret-request", queueMs = i, totalMs = 25, success = true,
    exchange = { stage = "decode_response", responseBytes = 412, handler = {
      rows = 43645, distinct = 41074, returned = 1000, cache_hit = true,
      labels = "secret-cell", keys_ms = 2, count_ms = 3,
    } },
  }
end
local lines = report.generate({
  status = { runtime_activity = { kind = "ark_request", detail = "secret-description" },
    lsp_status = { sessionBridge = { runtime = {
      activeOperation = { operation = "view_values", ageMs = 50, requestId = "secret-request" },
      recentRequests = records,
    } } } },
  release_status = {}, health_checks = {},
})
local text = table.concat(lines, "\n")
assert(text:find("view_values", 1, true), "report omitted operation evidence")
assert(text:find("43645", 1, true), "report omitted bounded handler counts")
assert(text:find("41074", 1, true))
assert(not text:find("secret", 1, true), "report leaked unapproved runtime strings")
local _, count = text:gsub("queue=", "")
assert(count == 8, "report must contain only the last eight requests")
