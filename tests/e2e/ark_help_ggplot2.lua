local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local ark_config = require("ark.config").defaults()

local test_file = "/tmp/ark_help_ggplot2.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "geom_point()",
})

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'ark_ggplot2_available <- requireNamespace("ggplot2", quietly = TRUE)',
  "Enter",
  "ark_ggplot2_available",
  "Enter",
})

ark_test.wait_for("ggplot2 availability probe", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil
end)

local has_ggplot2 = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id }):find("%[1%] TRUE") ~= nil
if not has_ggplot2 then
  ark_test.fail("ggplot2 is required for ArkHelp e2e coverage")
end

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'suppressPackageStartupMessages(library(ggplot2)); ark_ggplot2_loaded <- "package:ggplot2" %in% search()',
  "Enter",
  "ark_ggplot2_loaded",
  "Enter",
})

ark_test.wait_for("ggplot2 attach", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil
end)

ark_test.wait_for("detached session ready", 15000, function()
  local status = require("ark").status({ include_lsp = true })
  local lsp_status = type(status) == "table" and status.lsp_status or nil
  local detached = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
  return type(lsp_status) == "table"
    and lsp_status.available == true
    and lsp_status.sessionBridgeConfigured == true
    and type(detached) == "table"
    and detached.lastSessionUpdateStatus == "ready"
end)

local function help_topic_at(character)
  local topic, err = require("ark.lsp").help_topic(ark_config, 0, {
    line = 0,
    character = character,
  })
  if err then
    return nil, err
  end
  return { topic = topic }, nil
end

local function help_text(topic)
  return require("ark.lsp").help_text(ark_config, 0, topic)
end

local cases = {
  start = 0,
  middle = 5,
  underscore = 4,
  end_of_name = 10,
}

local result = {}
for label, character in pairs(cases) do
  local topic, topic_err = help_topic_at(character)
  if type(topic) ~= "table" or topic.topic ~= "geom_point" then
    ark_test.fail("unexpected help topic at " .. label .. ": " .. vim.inspect({
      topic = topic,
      error = topic_err,
    }))
  end

  local page, text_err = help_text(topic.topic)
  if type(page) ~= "table" or type(page.text) ~= "string" or not page.text:find("geom_point", 1, true) then
    ark_test.fail("unexpected help text at " .. label .. ": " .. vim.inspect({
      text = page,
      error = text_err,
    }))
  end

  local text = page.text

  if text:find("\b", 1, true) then
    ark_test.fail("help text still contains overstrike backspaces at " .. label .. ": " .. vim.inspect(text:sub(1, 80)))
  end

  local first_line = vim.split(text, "\n", { plain = true })[1] or ""
  if first_line ~= "Points" then
    ark_test.fail("unexpected cleaned help header at " .. label .. ": " .. vim.inspect(first_line))
  end

  result[label] = {
    topic = topic.topic,
    text_prefix = text:sub(1, 40),
  }
end

print(vim.json.encode(result))
