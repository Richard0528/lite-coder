-- mod-version:4
local util = require "plugins.prep.util"

local policy = {}

local SYSTEM = {
  coding = "You are an interview coach for a coding round. Give hints only. Never write the solution, a code patch, or the final algorithm in full. One short nudge or one question is enough.",
  design = "You are a system design interviewer. Ask one clarifying question or one follow-up about scale, data, or failure. Do not hand over a complete design. If the candidate is stuck, offer a partial hint.",
  debug = "You are helping a candidate debug code under a tight hint budget. Point at a suspicious region or a failing case. Do not paste corrected code.",
  explain = "The candidate has finished a read-and-explain round. You may now discuss their explanation directly, including what they missed.",
}

function policy.limit(session)
  if session.question.round == "debug" then return 3 end
  return nil
end

function policy.remaining(session)
  local limit = policy.limit(session)
  if not limit then return nil end
  return math.max(0, limit - (session.ai_count or 0))
end

function policy.can_ask(session)
  if not session or not session.question then
    return false, "Open a question first."
  end
  local round = session.question.round
  if session.ai_busy then
    return false, "Wait for the current AI reply."
  end
  if round == "explain" and not session.reviewed then
    return false, "AI assist unlocks after you click Done."
  end
  local left = policy.remaining(session)
  if left and left <= 0 then
    return false, "This debug round allows 3 AI questions."
  end
  return true
end

function policy.intro(session)
  local round = session.question.round
  if round == "coding" then
    return "Hints only. Ask for a nudge, not the solution."
  elseif round == "design" then
    return "The assistant interviews you. Ask it to probe your design."
  elseif round == "debug" then
    return "3 questions for this session. It will not paste the fix."
  elseif round == "explain" and not session.reviewed then
    return "Locked until you click Done."
  elseif round == "explain" then
    return "You can ask about your explanation."
  end
  return ""
end

local function question_context(question)
  local parts = { "Question: " .. (question.title or "") }
  if question.difficulty then
    parts[#parts + 1] = "Difficulty: " .. question.difficulty
  end
  if question.content_md and question.content_md ~= "" then
    parts[#parts + 1] = util.clip(question.content_md, 3500)
  end
  if question.round == "explain" and question.code then
    parts[#parts + 1] = "Code:\n" .. util.clip(question.code, 3500)
  end
  if question.round == "debug" and question.failing_test then
    parts[#parts + 1] = "Known failing case: " .. util.clip(question.failing_test, 500)
  end
  return table.concat(parts, "\n\n")
end

function policy.messages(session, history)
  local messages = {
    {
      role = "system",
      content = (SYSTEM[session.question.round] or SYSTEM.coding) .. "\n\n" .. question_context(session.question),
    },
  }
  for _, item in ipairs(history or {}) do
    messages[#messages + 1] = { role = item.role, content = item.content }
  end
  return messages
end

return policy
