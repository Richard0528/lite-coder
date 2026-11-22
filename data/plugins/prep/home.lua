-- mod-version:4
local core = require "core"
local style = require "core.style"
local EmptyView = require "core.emptyview"
local memory = require "plugins.prep.memory"
local quiz = require "plugins.prep.quiz"
local util = require "plugins.prep.util"

local function add_hit(x, y, w, h, action)
  quiz.hits[#quiz.hits + 1] = { x = x, y = y, w = w, h = h, action = action }
end

local function draw_wrapped(font, color, text, left, y, width)
  local rows = util.wrap(font, text, width)
  for _, row in ipairs(rows) do
    renderer.draw_text(font, row, left, y, color)
    y = y + font:get_height()
  end
  return y
end

function EmptyView:get_name()
  return "Home"
end

function EmptyView:draw()
  self:draw_background(style.background)
  quiz.hits = {}
  local deck, item = quiz.current()
  local width = math.min(self.size.x - style.padding.x * 6, style.font:get_width("n") * 68)
  local left = self.position.x + (self.size.x - width) / 2
  local y = self.position.y + style.padding.y * 3

  local title = "Prep"
  renderer.draw_text(style.big_font, title, left, y, style.dim)
  y = y + style.big_font:get_height() + style.padding.y

  if not item then
    y = draw_wrapped(style.font, style.dim, "No quiz questions yet.", left, y, width)
  else
    local total = #deck.items
    local label = deck.completed and "Daily quiz complete" or string.format("Daily quiz  %d / %d", deck.cursor, total)
    y = draw_wrapped(style.font, style.dim, label, left, y, width)
    y = y + style.padding.y

    if item.kind == "card" then
      if item.title then
        y = draw_wrapped(style.font, style.dim, item.title, left, y, width)
      end
      y = draw_wrapped(style.font, style.text, item.front or "", left, y, width)
      y = y + style.padding.y
      if not deck.revealed then
        local h = style.font:get_height() + style.padding.y
        renderer.draw_text(style.font, "Show answer", left, y, style.accent or style.text)
        add_hit(left, y, width, h, function() quiz.answer(1) end)
        y = y + h
      else
        y = draw_wrapped(style.font, style.text, item.back or "", left, y, width)
        y = y + style.padding.y
        local h = style.font:get_height() + style.padding.y
        local knew = deck.picked == 1
        local missed = deck.picked == 2
        renderer.draw_text(style.font, "1  Knew it", left, y, knew and util.good() or style.dim)
        add_hit(left, y, width / 2, h, function() quiz.answer(1) end)
        renderer.draw_text(style.font, "2  Missed it", left + width / 2, y, missed and util.err() or style.dim)
        add_hit(left + width / 2, y, width / 2, h, function() quiz.answer(2) end)
        y = y + h
      end
    else
      local question = item.question or {}
      y = draw_wrapped(style.font, style.text, question.q or "", left, y, width)
      y = y + style.padding.y / 2
      local choices = question.choices or {}
      local answer = question.answer
      for index, choice in ipairs(choices) do
        local h = style.font:get_height()
        local color = style.text
        if deck.revealed and index == answer then
          color = util.good()
        elseif deck.revealed and index == deck.picked and index ~= answer then
          color = util.err()
        elseif not deck.revealed then
          color = style.text
        else
          color = style.dim
        end
        local text = index .. "  " .. choice
        local rows = util.wrap(style.font, text, width)
        local block = #rows * h
        local top = y
        y = draw_wrapped(style.font, color, text, left, y, width)
        if not deck.picked then
          add_hit(left, top, width, math.max(block, h), function() quiz.answer(index) end)
        end
        y = y + math.floor(style.padding.y / 2)
      end
      if deck.revealed and question.explain and question.explain ~= "" then
        y = y + style.padding.y
        y = draw_wrapped(style.font, style.dim, question.explain, left, y, width)
      end
    end

    if deck.picked then
      y = y + style.padding.y
      local h = style.font:get_height() + style.padding.y
      local label_next = deck.cursor >= #deck.items and "Done" or "Next"
      renderer.draw_text(style.font, label_next, left, y, style.accent or style.text)
      add_hit(left, y, width, h, function() quiz.next() end)
      y = y + h
    end
  end

  local stats = memory.stats()
  local foot = string.format("Streak %d    Solved %d    Attempted %d", quiz.streak(), stats.solved, stats.attempted)
  local foot_y = self.position.y + self.size.y - style.font:get_height() * 2 - style.padding.y * 2
  renderer.draw_text(style.font, foot, left, foot_y, style.dim)
  if stats.last and stats.last.meta then
    local meta = stats.last.meta
    local continue = "Continue   " .. (meta.title or stats.last.id)
    local cy = foot_y - style.font:get_height() - style.padding.y
    renderer.draw_text(style.font, continue, left, cy, style.text)
    add_hit(left, cy, width, style.font:get_height() + style.padding.y, function()
      local round = meta.round
      local id = stats.last.id or ""
      local slug = id:match("^" .. (round or "") .. "%-(.+)$")
      if round and slug then
        require("plugins.prep.session").open(round, slug)
      end
    end)
  end
end

local view_mouse_pressed = EmptyView.on_mouse_pressed
function EmptyView:on_mouse_pressed(button, x, y, clicks)
  if view_mouse_pressed and view_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  for _, hit in ipairs(quiz.hits) do
    if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
      hit.action()
      core.redraw = true
      return true
    end
  end
  return false
end

return {}
