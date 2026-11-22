-- mod-version:4
local core = require "core"
local json = require "plugins.prep.json"
local Doc = require "core.doc"
local bank = require "plugins.prep.bank"
local md = require "plugins.prep.md_view"
local memory = require "plugins.prep.memory"
local policy = require "plugins.prep.policy"
local state = require "plugins.prep.state"
local util = require "plugins.prep.util"
local OutputView = require "plugins.prep.output_view"

local session = {}

local function decode_file(path)
  local text = util.read_file(path)
  if not text or text == "" then return nil end
  local ok, value = pcall(json.decode, text, 1, nil)
  if ok and type(value) == "table" then return value end
  return nil
end

local function state_path(dir)
  return util.join(dir, "state.json")
end

function session.setup()
  local question_doc, question_view = md.create("Question", "Open a question from the sidebar.\n", true)
  local output = OutputView()
  local scratch_doc, scratch_view = md.create("Scratchpad", "Open a question to use the scratchpad.\n", true)
  local ai_doc, ai_view = md.create("AI", "Open a question to use AI assist.\n", true)
  local review_doc, review_view = md.create("Review", "", true)
  state.output = output
  state.docs = {
    question = question_doc,
    scratch = scratch_doc,
    ai = ai_doc,
    review = review_doc,
  }
  state.views = {
    Question = question_view,
    Output = output,
    Scratchpad = scratch_view,
    AI = ai_view,
    Review = review_view,
  }
  return question_view
end

function session.show(name)
  local view = state.views[name]
  if view and state.panel then
    state.panel:set_active_view(view)
  end
end

local function save_doc(doc)
  if doc and doc.abs_filename and not doc.read_only and doc:is_dirty() then
    doc:save()
  end
end

function session.save_files()
  local current = state.session
  if not current then return end
  save_doc(current.solution_doc)
  save_doc(state.docs.scratch)
end

function session.save_state(current)
  current = current or state.session
  if not current or not current.dir then return end
  util.write_file(state_path(current.dir), json.encode({
    language = current.language,
    ai_count = current.ai_count or 0,
    reviewed = current.reviewed and true or false,
    messages = current.messages or {},
  }))
end

local function template_for(question, language)
  local templates = question.templates or {}
  if question.round == "debug" then
    local origin = question.language or "python"
    local matches = (language == "javascript" and origin == "javascript") or (language ~= "javascript" and origin ~= "javascript")
    if matches and question.buggy_code then return question.buggy_code end
    local comment = language == "javascript" and "// " or "# "
    return comment .. "The buggy starter for this question is " .. origin .. ".\n"
  end
  if language == "javascript" then
    return templates.javascript or templates.nodejs or "var solve = function() {\n};\n"
  end
  return templates.python3 or templates.python or "class Solution:\n    def solve(self):\n        pass\n"
end

local function solution_file(question, language)
  if question.round == "design" then return "design.md" end
  if question.round == "explain" then
    local ext = (question.language == "javascript") and "js" or "py"
    return "code." .. ext
  end
  if language == "javascript" then return "solution.js" end
  return "solution.py"
end

local function scratch_seed(question)
  if question.round == "design" then
    return "# Notes\n\n"
  elseif question.round == "explain" then
    return "# What it does\n\n# Complexity\n\n# Edge cases\n\n"
  end
  return "# Scratch\n\n"
end

local function design_seed()
  return "# Requirements\n\n# API\n\n# Data model\n\n# Scale\n\n# Tradeoffs\n\n"
end

function session.question_markdown(question)
  local lines = { "# " .. (question.title or question.slug), "" }
  if question.difficulty and question.difficulty ~= "" then
    lines[#lines + 1] = question.difficulty
    lines[#lines + 1] = ""
  end
  local past = memory.summaries(question)
  if #past > 0 then
    lines[#lines + 1] = "## Previous sessions"
    lines[#lines + 1] = ""
    for _, item in ipairs(past) do
      lines[#lines + 1] = string.format("- %s **%s** — %s", item.date or "", item.verdict or "", item.summary or "")
      if item.missing and item.missing ~= "" then
        lines[#lines + 1] = "  Missing: " .. item.missing
      end
    end
    lines[#lines + 1] = ""
  end
  if question.content_md and question.content_md ~= "" then
    lines[#lines + 1] = question.content_md
  elseif question.round == "explain" then
    lines[#lines + 1] = "Read the code and explain what it does, its complexity, and the edge cases."
  elseif question.round == "debug" then
    lines[#lines + 1] = "Find and fix the bug. Run the code, then write the diagnosis in the scratchpad."
  end
  if question.round == "debug" and question.failing_test and question.failing_test ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Failing case"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```"
    lines[#lines + 1] = question.failing_test
    lines[#lines + 1] = "```"
  end
  if type(question.hints) == "table" and #question.hints > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Hints"
    lines[#lines + 1] = ""
    for index, hint in ipairs(question.hints) do
      lines[#lines + 1] = index .. ". " .. tostring(hint)
    end
  end
  return table.concat(lines, "\n")
end

local function render_ai(current)
  local lines = { "# AI", "", policy.intro(current), "" }
  for _, message in ipairs(current.messages or {}) do
    lines[#lines + 1] = message.role == "user" and "## You" or "## Assistant"
    lines[#lines + 1] = ""
    lines[#lines + 1] = message.content or ""
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

function session.refresh_ai(note)
  local current = state.session
  if not current then return end
  local text = render_ai(current)
  if note and note ~= "" then
    text = text .. "\n" .. note .. "\n"
  end
  local path = util.join(current.dir, "ai.md")
  util.write_file(path, text)
  md.load_file(state.docs.ai, path, true)
end

local function close_doc_views(doc)
  if not doc then return end
  local root = core.root_view.root_node
  for _, view in ipairs(core.get_views_referencing_doc(doc)) do
    local node = root:get_node_for_view(view)
    if node and not node.locked then
      node:close_view(root, view)
    end
  end
end

local function adopt_file(path, seed, read_only)
  if not system.get_file_info(path) then
    util.write_file(path, seed or "")
  end
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == path then
      doc.read_only = read_only and true or false
      core.root_view:open_doc(doc)
      return doc
    end
  end
  local doc = Doc(path, path, false)
  doc.read_only = read_only and true or false
  table.insert(core.docs, doc)
  core.root_view:open_doc(doc)
  return doc
end

local function open_editor(current)
  local question = current.question
  local read_only = question.round == "explain"
  local name = solution_file(question, current.language)
  local path = util.join(current.dir, name)
  local seed
  if question.round == "design" then
    seed = design_seed()
  elseif question.round == "explain" then
    seed = question.code or ""
  else
    seed = template_for(question, current.language)
  end
  current.solution_path = path
  current.solution_doc = adopt_file(path, seed, read_only)
end

function session.open(round, slug)
  local question = bank.get(round, slug)
  if not question then
    core.error("Question not found: %s", slug)
    return
  end
  local id = round .. "-" .. question.slug
  if state.session and state.session.id == id then
    if state.session.solution_doc then
      core.root_view:open_doc(state.session.solution_doc)
    end
    return
  end
  if state.session then
    session.save_files()
    session.save_state()
    close_doc_views(state.session.solution_doc)
  end
  local current = state.sessions[id]
  if not current then
    local dir = util.sessions_dir() .. PATHSEP .. round .. PATHSEP .. util.safe_name(question.slug)
    util.ensure_dir(dir)
    local saved = decode_file(state_path(dir)) or {}
    local language = saved.language
    if language ~= "python" and language ~= "javascript" then
      if question.language == "javascript" then language = "javascript" else language = "python" end
    end
    current = {
      id = id,
      question = question,
      dir = dir,
      language = language,
      ai_count = saved.ai_count or 0,
      reviewed = saved.reviewed and true or false,
      messages = saved.messages or {},
      last_output = "",
      running = false,
    }
    state.sessions[id] = current
  end
  local dir = current.dir
  state.session = current
  memory.touch(question)

  local question_path = util.join(dir, "question.md")
  util.write_file(question_path, session.question_markdown(question))
  md.load_file(state.docs.question, question_path, true)

  local scratch_path = util.join(dir, "scratchpad.md")
  if not system.get_file_info(scratch_path) then
    util.write_file(scratch_path, scratch_seed(question))
  end
  md.load_file(state.docs.scratch, scratch_path, false)

  session.refresh_ai()
  local review_path = util.join(dir, "review.md")
  if system.get_file_info(review_path) then
    md.load_file(state.docs.review, review_path, true)
  else
    state.docs.review.read_only = false
    state.docs.review:set_filename(review_path, review_path)
    md.set_text(state.docs.review, "Click Done when you want a review.\n")
    state.docs.review.read_only = true
  end

  open_editor(current)
  session.show("Question")
  if state.sidebar then state.sidebar:select_question(round, question.slug) end
  if state.output then state.output:clear() end
  core.redraw = true
end

function session.toggle_language()
  local current = state.session
  if not current then return end
  local round = current.question.round
  if round ~= "coding" and round ~= "debug" then return end
  session.save_files()
  local old_doc = current.solution_doc
  current.language = current.language == "javascript" and "python" or "javascript"
  open_editor(current)
  if old_doc ~= current.solution_doc then close_doc_views(old_doc) end
  session.save_state()
  core.redraw = true
end

function session.show_review(markdown, current)
  current = current or state.session
  if not current then return end
  local path = util.join(current.dir, "review.md")
  util.write_file(path, markdown)
  if state.session == current then
    md.load_file(state.docs.review, path, true)
    session.show("Review")
  end
end

function session.ask()
  local current = state.session
  local ok, reason = policy.can_ask(current)
  if not ok then
    core.error("%s", reason)
    return
  end
  if core.active_view == core.command_view then
    core.error("Close the command prompt, then try again.")
    return
  end
  core.command_view:enter("Ask", {
    submit = function(text)
      text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local active = current
      if text == "" or not active then return end
      -- Re-check here: the prompt may have been open while another reply landed.
      local allowed, why = policy.can_ask(active)
      if not allowed then
        core.error("%s", why)
        return
      end
      active.messages[#active.messages + 1] = { role = "user", content = text }
      -- Spend the question now so rapid asks cannot slip past the limit.
      active.ai_busy = true
      active.ai_count = (active.ai_count or 0) + 1
      session.refresh_ai("_Thinking..._")
      session.save_state(active)
      session.show("AI")
      local llm = require "plugins.prep.llm"
      llm.complete(policy.messages(active, active.messages), function(err, content)
        active.ai_busy = false
        if err then
          active.ai_count = math.max(0, (active.ai_count or 1) - 1)
        end
        active.messages[#active.messages + 1] = {
          role = "assistant",
          content = err and ("Error: " .. err) or (content or ""),
        }
        if state.session == active then
          session.refresh_ai()
        else
          util.write_file(util.join(active.dir, "ai.md"), render_ai(active))
        end
        session.save_state(active)
        core.redraw = true
      end, 0.4)
    end,
  })
end

return session
