local M = {}

function M.record(event, value_ms, metadata)
  local path = vim.env.ARK_PERF_SAMPLES_FILE
  if type(path) ~= "string" or path == "" then
    return
  end

  metadata = metadata or {}
  local record = vim.tbl_extend("force", {
    schema_version = 1,
    benchmark = vim.fn.fnamemodify(metadata.test or "unknown", ":t:r"),
    event = event,
    condition = metadata.condition or "unspecified",
    fixture = metadata.fixture or "unspecified",
    value_ms = value_ms,
    unit = "ms",
  }, metadata)
  record.test = nil
  vim.fn.writefile({ vim.json.encode(record) }, path, "a")
end

return M
