-- mod-version:4
-- priority:50
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local StatusView = require "core.statusview"
local EmptyView = require "core.emptyview"

-- Reading config.plugins.<name> creates a table, so a nil check never matches.
-- Hide the file tree until the user toggles it. The plugin stays loaded,
-- which keeps the treeview:toggle command available.
local tree = config.plugins.treeview
if type(tree) == "table" and tree.visible == nil then
  tree.visible = false
end

local util = require "plugins.prep.util"

local prep = config.plugins.prep
local function fill(key, value)
  if prep[key] == nil then prep[key] = value end
end
fill("sidebar_size", 220 * SCALE)
fill("panel_size", 360 * SCALE)
fill("timeout", 10)
fill("python", util.bundled_bin("python") or "python3")
fill("node", util.bundled_bin("node") or "node")
fill("java", "java")
fill("javac", "javac")
fill("fetch_script", "")
if type(prep.llm) ~= "table" then prep.llm = {} end
if prep.llm.base_url == nil then prep.llm.base_url = "https://api.openai.com/v1" end
if prep.llm.model == nil then prep.llm.model = "gpt-4o-mini" end
if prep.llm.api_key_env == nil then prep.llm.api_key_env = "OPENAI_API_KEY" end

local bank = require "plugins.prep.bank"
local state = require "plugins.prep.state"
local session = require "plugins.prep.session"
local runner = require "plugins.prep.runner"
local review = require "plugins.prep.review"
local leetcode = require "plugins.prep.leetcode"
local quiz = require "plugins.prep.quiz"
local policy = require "plugins.prep.policy"
local Sidebar = require "plugins.prep.sidebar"
local RunBar = require "plugins.prep.runbar"
require "plugins.prep.home"

local function bind_width(view, box)
  view.init_prep_size = true
  function view:set_target_size(axis, value)
    if axis == "x" then
      box.x = value
      return true
    end
  end
  local base = view.update
  function view:update()
    if self.init_prep_size then
      self.size.x = box.x
      self.init_prep_size = false
    else
      self:move_towards(self.size, "x", box.x)
    end
    base(self)
  end
end

local sidebar = Sidebar()
state.sidebar = sidebar
local primary = core.root_view:get_primary_node()
primary:split("left", sidebar, { x = true }, true)

-- Soft-wrap the editor and the right-hand documents to the pane width.
-- The line-wrapping plugin reads this when each document view is created.
local wrap = config.plugins.linewrapping
if type(wrap) == "table" then
  wrap.mode = "word"
  wrap.guide = false
  wrap.enable_by_default = true
end

local question_view = session.setup()
primary = core.root_view:get_primary_node()
-- Lock the pane after the tabs exist. add_view refuses a node that is already locked.
local panel = primary:split("right", question_view)
state.panel = panel
panel:add_view(state.views.Output)
panel:add_view(state.views.Scratchpad)
panel:add_view(state.views.AI)
panel:add_view(state.views.Review)
panel:set_active_view(question_view)
panel.locked = { x = true }
panel.resizable = true

local panel_box = { x = config.plugins.prep.panel_size }
for _, view in pairs(state.views) do
  bind_width(view, panel_box)
end

primary = core.root_view:get_primary_node()
local runbar = RunBar()
state.runbar = runbar
primary:split("up", runbar, { y = true })

local function runnable()
  local current = state.session
  return current and (current.question.round == "coding" or current.question.round == "debug")
end

command.add(nil, {
  ["prep:find-question"] = function()
    local labels = {}
    local by_label = {}
    for _, round in ipairs(bank.rounds) do
      for _, question in ipairs(bank.questions(round.id)) do
        local label = round.label .. "  " .. (question.difficulty or "") .. "  " .. (question.title or question.slug)
        labels[#labels + 1] = label
        by_label[label] = { round = round.id, slug = question.slug }
      end
    end
    core.command_view:enter("Find Question", {
      submit = function(text, item)
        local picked = item and by_label[item.text]
        if picked then session.open(picked.round, picked.slug) end
      end,
      suggest = function(text)
        local matched = common.fuzzy_match(labels, text) or {}
        local items = {}
        for i, name in ipairs(matched) do
          items[i] = { text = name }
        end
        return items
      end,
    })
  end,
  ["prep:sync-questions"] = function() leetcode.sync() end,
  ["prep:leetcode-login"] = function() leetcode.capture() end,
  ["prep:leetcode-logout"] = function() leetcode.logout() end,
  ["prep:toggle-language"] = function() runner.toggle_language() end,
  ["prep:stop"] = function() runner.stop() end,
})

command.add(function() return runnable() end, {
  ["prep:run"] = function() runner.run(false) end,
  ["prep:run-examples"] = function() runner.run(true) end,
})

command.add(function() return state.session ~= nil end, {
  ["prep:done"] = function() review.start() end,
  ["prep:ask-ai"] = function() session.ask() end,
  ["prep:show-question"] = function() session.show("Question") end,
  ["prep:show-output"] = function() session.show("Output") end,
  ["prep:show-scratchpad"] = function() session.show("Scratchpad") end,
  ["prep:show-ai"] = function() session.show("AI") end,
  ["prep:show-review"] = function() session.show("Review") end,
})

command.add(function()
  return core.active_view:is(EmptyView)
end, {
  ["prep:quiz-1"] = function() quiz.answer(1) core.redraw = true end,
  ["prep:quiz-2"] = function() quiz.answer(2) core.redraw = true end,
  ["prep:quiz-3"] = function() quiz.answer(3) core.redraw = true end,
  ["prep:quiz-4"] = function() quiz.answer(4) core.redraw = true end,
  ["prep:quiz-next"] = function() quiz.next() core.redraw = true end,
})

local function prep_surface_focused()
  if not state.session then return false end
  local view = core.active_view
  if not view then return false end
  for _, name in ipairs({ "Question", "Output", "Scratchpad", "AI", "Review" }) do
    if view == state.views[name] then return true end
  end
  return view.doc and view.doc == state.session.solution_doc
end

local mod = PLATFORM == "Mac OS X" and "cmd" or "ctrl"
local opt = PLATFORM == "Mac OS X" and "option" or "alt"
keymap.add_direct({
  [mod .. "+return"] = {
    function()
      if not runnable() or not prep_surface_focused() then return false end
      command.perform("prep:run")
    end,
    "doc:newline-below",
  },
  [mod .. "+shift+return"] = {
    function()
      if not prep_surface_focused() then return false end
      command.perform("prep:done")
    end,
    "doc:newline-above",
  },
})
keymap.add({
  [mod .. "+shift+a"] = { "prep:ask-ai" },
  [mod .. "+" .. opt .. "+p"] = { "prep:find-question" },
  ["1"] = { "prep:quiz-1" },
  ["2"] = { "prep:quiz-2" },
  ["3"] = { "prep:quiz-3" },
  ["4"] = { "prep:quiz-4" },
  ["space"] = { "prep:quiz-next" },
})

core.status_view:add_item({
  name = "prep:menu",
  alignment = StatusView.Item.LEFT,
  position = 1,
  get_item = function()
    if state.sync_status and state.sync_status ~= "" then
      return { style.text, state.sync_status }
    end
    if state.leetcode_busy then
      return { style.text, "Menu  signing in" }
    end
    local who = state.leetcode_user
    if who and who ~= "" then
      return { style.text, "Menu  " .. who }
    end
    return { style.text, "Menu" }
  end,
  tooltip = "Prep menu",
  command = function(button, x, y)
    local menu = core.root_view.context_menu
    local items = {
      { text = "Log in to LeetCode", command = "prep:leetcode-login" },
      { text = "Sync questions", command = "prep:sync-questions" },
    }
    if state.leetcode_user and state.leetcode_user ~= "" then
      items[#items + 1] = { text = "Sign out of LeetCode", command = "prep:leetcode-logout" }
    end
    menu:show(x, y, items)
  end,
})

core.status_view:add_item({
  name = "prep:language",
  alignment = StatusView.Item.RIGHT,
  predicate = runnable,
  get_item = function()
    return { style.text, runner.language_label(state.session.language) }
  end,
  command = "prep:toggle-language",
  tooltip = "Cycle Python, Node, and Java",
})

core.status_view:add_item({
  name = "prep:ai-left",
  alignment = StatusView.Item.RIGHT,
  predicate = function()
    return state.session and state.session.question.round == "debug"
  end,
  get_item = function()
    return { style.dim, "AI " .. tostring(policy.remaining(state.session) or 0) }
  end,
})

core.status_view:add_item({
  name = "prep:leetcode",
  alignment = StatusView.Item.RIGHT,
  predicate = function() return state.leetcode_user ~= nil end,
  get_item = function()
    return { style.dim, "LC " .. state.leetcode_user }
  end,
  tooltip = "LeetCode account",
})

leetcode.restore_user()

-- Setup leaves focus on the Question tab. Other plugins (the file tree) split
-- whichever node is active when they load, and the quiz keys need the home
-- view focused, so hand focus back to the editor pane.
do
  local editor_node = core.root_view:get_primary_node()
  if editor_node and editor_node.active_view then
    core.set_active_view(editor_node.active_view)
  end
end

return {
  bank = bank,
  session = session,
  open = session.open,
}
