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

local function canonical_language(language)
  if type(language) ~= "string" then return nil end
  language = language:lower()
  if language == "javascript" or language == "nodejs" or language == "node" then
    return "javascript"
  end
  if language == "java" then return "java" end
  if language == "python" or language == "python3" then return "python" end
  return nil
end

local JAVA_WORDS = {}
for word in ([[ abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var record sealed permits yield ]]):gmatch("%S+") do
  JAVA_WORDS[word] = true
end

local JAVA_PRIMITIVE = {
  integer = "int", int = "int", long = "long", double = "double", float = "float",
  boolean = "boolean", bool = "boolean", string = "String", character = "char",
  char = "char", void = "void", short = "short", byte = "byte",
}

local JAVA_BOX = {
  int = "Integer", long = "Long", double = "Double", float = "Float",
  boolean = "Boolean", char = "Character", short = "Short", byte = "Byte",
}

local function java_type(type_name, boxed)
  if type(type_name) ~= "string" then return "Object" end
  type_name = type_name:gsub("%s+", ""):gsub("%*", "")
  if type_name == "" then return "Object" end
  local inner = type_name:match("^[Ll]ist<(.*)>$")
  if inner then return "List<" .. java_type(inner, true) .. ">" end
  inner = type_name:match("^[Ss]et<(.*)>$")
  if inner then return "Set<" .. java_type(inner, true) .. ">" end
  if type_name:sub(-2) == "[]" then
    return java_type(type_name:sub(1, -3), false) .. "[]"
  end
  local mapped = JAVA_PRIMITIVE[type_name] or type_name
  if boxed and JAVA_BOX[mapped] then return JAVA_BOX[mapped] end
  return mapped
end

local function java_ident(name, fallback)
  if type(name) == "string" and name:match("^[%a_][%w_]*$") and not JAVA_WORDS[name] then
    return name
  end
  return fallback
end

local function java_return_line(jtype)
  if jtype == "void" then return "" end
  if jtype == "boolean" then return "        return false;\n" end
  if jtype == "int" or jtype == "long" or jtype == "short" or jtype == "byte"
    or jtype == "char" or jtype == "float" or jtype == "double" then
    return "        return 0;\n"
  end
  return "        return null;\n"
end

local function return_type_name(meta)
  local ret = meta["return"]
  if type(ret) == "table" then return ret.type end
  if type(ret) == "string" then return ret end
  return "void"
end

local function java_param(param, index)
  local name, type_name
  if type(param) == "table" then
    name = param.name
    type_name = param.type
  end
  return java_type(type_name, false) .. " " .. java_ident(name, "arg" .. tostring(index))
end

local function java_template(question)
  local templates = question.templates or {}
  if type(templates.java) == "string" and templates.java ~= "" then
    return templates.java
  end
  local meta = question.meta
  if type(meta) == "table" and type(meta.name) == "string" and meta.name ~= "" then
    local parts = {}
    for index, param in ipairs(meta.params or {}) do
      parts[#parts + 1] = java_param(param, index)
    end
    local ret = java_type(return_type_name(meta), false)
    local method = java_ident(meta.name, "solve")
    return "import java.util.*;\n\npublic class Solution {\n    public "
      .. ret .. " " .. method .. "(" .. table.concat(parts, ", ") .. ") {\n"
      .. java_return_line(ret)
      .. "    }\n}\n"
  end
  return "import java.util.*;\n\npublic class Solution {\n    public Object solve() {\n        return null;\n    }\n}\n"
end

local function template_for(question, language)
  local templates = question.templates or {}
  if question.round == "debug" then
    local origin = canonical_language(question.language) or "python"
    if origin == canonical_language(language) and question.buggy_code then
      return question.buggy_code
    end
    local comment = canonical_language(language) == "python" and "# " or "// "
    return comment .. "The buggy starter for this question is " .. (question.language or origin) .. ".\n"
  end
  if language == "java" then return java_template(question) end
  if language == "javascript" then
    return templates.javascript or templates.nodejs or "var solve = function() {\n};\n"
  end
  return templates.python3 or templates.python or "class Solution:\n    def solve(self):\n        pass\n"
end

local function solution_file(question, language)
  if question.round == "design" then return "design.md" end
  if question.round == "explain" then
    local origin = canonical_language(question.language) or "python"
    if origin == "javascript" then return "code.js" end
    if origin == "java" then return "code.java" end
    return "code.py"
  end
  if language == "javascript" then return "solution.js" end
  if language == "java" then return "Solution.java" end
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
    local language = canonical_language(saved.language)
    if not language then
      language = canonical_language(question.language) or "python"
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
  local next_language = { python = "javascript", javascript = "java", java = "python" }
  current.language = next_language[current.language] or "python"
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
