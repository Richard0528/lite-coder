-- mod-version:4
local core = require "core"
local llm = require "plugins.prep.llm"
local memory = require "plugins.prep.memory"
local state = require "plugins.prep.state"
local util = require "plugins.prep.util"

local review = {}
local busy = false

local INSTRUCTIONS = [[
Review this interview attempt. Respond with one JSON object and no other text.
Use these keys:
- verdict: "solved", "partial", or "unsolved"
- summary: at most 2 sentences
- missing_piece: at most 1 sentence, the gap between the attempt and a working answer
- complexity: a short time/space note, or ""
- issues: up to 3 short strings
- takeaways: up to 3 short strings
- cards: up to 2 objects {"front","back"} a future flashcard could use
- review_md: a markdown write-up the candidate can reread

Keep summary and missing_piece concrete. If the attempt is incomplete, say what is missing. Do not invent code the candidate did not write.
]]

local function list_text(items)
  if type(items) ~= "table" or #items == 0 then return "" end
  local lines = {}
  for index, item in ipairs(items) do
    if index > 3 then break end
    lines[#lines + 1] = "- " .. tostring(item)
  end
  return table.concat(lines, "\n")
end

local function fallback_markdown(raw)
  return "# Review\n\nThe model did not return JSON. Raw reply:\n\n" .. tostring(raw or "")
end

function review.render(data, raw)
  if type(data) ~= "table" then
    return fallback_markdown(raw)
  end
  local lines = {
    "# Review",
    "",
    "**" .. tostring(data.verdict or "attempted") .. "**",
    "",
    tostring(data.summary or ""),
  }
  if data.missing_piece and data.missing_piece ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Missing: " .. data.missing_piece
  end
  if data.complexity and data.complexity ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Complexity: " .. data.complexity
  end
  local issues = list_text(data.issues)
  if issues ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Issues"
    lines[#lines + 1] = issues
  end
  local takeaways = list_text(data.takeaways)
  if takeaways ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Takeaways"
    lines[#lines + 1] = takeaways
  end
  if data.review_md and data.review_md ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = data.review_md
  end
  return table.concat(lines, "\n")
end

local function prompt_for(session)
  local question = session.question
  local session_mod = require "plugins.prep.session"
  session_mod.save_files()
  local code = ""
  if session.solution_doc then
    code = util.doc_text(session.solution_doc)
  elseif question.code then
    code = question.code
  end
  local scratch = session.scratch_doc and util.doc_text(session.scratch_doc) or ""
  local past = {}
  for _, item in ipairs(memory.summaries(question)) do
    past[#past + 1] = string.format("%s %s — %s Missing: %s", item.date or "", item.verdict or "", item.summary or "", item.missing or "")
  end
  local hidden = {}
  if question.round == "debug" and question.correct_code then
    hidden[#hidden + 1] = "Reference solution (do not assume the candidate saw this):\n" .. util.clip(question.correct_code, 4000)
  end
  if question.round == "explain" and question.expected_points then
    local points = question.expected_points
    if type(points) == "table" then points = table.concat(points, "\n- ") end
    hidden[#hidden + 1] = "Points a strong explanation would cover:\n- " .. tostring(points)
  end
  return INSTRUCTIONS .. "\n\nQuestion:\n" .. util.clip(question.content_md or question.title or "", 4000)
    .. "\n\nCandidate writing:\n" .. util.clip(code, 6000)
    .. "\n\nScratchpad:\n" .. util.clip(scratch, 3000)
    .. "\n\nLast run:\n" .. util.clip(session.last_output or "", 1500)
    .. "\n\nPrevious sessions:\n" .. (#past > 0 and table.concat(past, "\n") or "(none)")
    .. (#hidden > 0 and ("\n\n" .. table.concat(hidden, "\n\n")) or "")
end

function review.start()
  local session = state.session
  if not session then
    core.error("Open a question first.")
    return
  end
  if busy then
    core.error("A review is already running.")
    return
  end
  busy = true
  core.status_view:show_message("i", require("core.style").text, "Reviewing...")
  local messages = {
    { role = "system", content = "You review interview practice attempts and reply with JSON only." },
    { role = "user", content = prompt_for(session) },
  }
  llm.complete(messages, function(err, content)
    busy = false
    if err then
      core.error("Review failed: %s", err)
      return
    end
    local data = llm.extract_json(content)
    if type(data) ~= "table" then
      data = {
        verdict = "attempted",
        summary = util.clip(content, 240),
        missing_piece = "",
        review_md = content,
      }
    end
    data.summary = util.clip(data.summary, 240)
    data.missing_piece = util.clip(data.missing_piece, 160)
    local markdown = review.render(data, content)
    local session_mod = require "plugins.prep.session"
    -- Write to the question that was open when Done was clicked, even if
    -- the user has since opened a different one.
    session.reviewed = true
    -- Done ends the attempt, so the next attempt gets a fresh AI budget.
    session.ai_count = 0
    session_mod.save_state(session)
    session_mod.show_review(markdown, session)
    memory.record_review(session.question, data)
    if state.sidebar then state.sidebar:refresh() end
    core.status_view:show_message("i", require("core.style").text, "Review saved")
    core.redraw = true
  end, 0.2)
end

return review
