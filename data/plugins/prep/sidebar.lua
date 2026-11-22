-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local bank = require "plugins.prep.bank"
local memory = require "plugins.prep.memory"

local attempted_bg = { common.color "#E6B325" }
local attempted_hover = { common.color "#F0C44A" }
local solved_bg = { common.color "#3FA86A" }
local solved_hover = { common.color "#52BE7C" }
local status_text = { common.color "#1c1c1f" }

local Sidebar = View:extend()

function Sidebar:__tostring() return "PrepSidebar" end

function Sidebar:new()
  Sidebar.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.target_size = config.plugins.prep.sidebar_size
  self.round_index = 1
  self.expanded = { Easy = true, Medium = true, Hard = true }
  self.hovered_key = nil
  self.hovered_tab = nil
  self.selected_id = nil
  self.tab_hits = {}
end

function Sidebar:get_name()
  return "Prep"
end

function Sidebar:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(value, self:tab_width() + 120 * SCALE)
    return true
  end
end

function Sidebar:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end
  Sidebar.super.update(self)
end

function Sidebar:get_round()
  return bank.rounds[self.round_index] or bank.rounds[1]
end

function Sidebar:item_height()
  return style.font:get_height() + style.padding.y
end

function Sidebar:tab_height()
  return style.font:get_height() + style.padding.y * 2
end

function Sidebar:tab_width()
  local widest = 0
  for _, round in ipairs(bank.rounds) do
    widest = math.max(widest, style.font:get_width(round.label))
  end
  return widest + style.padding.x * 2
end

function Sidebar:in_tab_column(px, py)
  return px >= self.position.x and px < self.position.x + self:tab_width()
    and py >= self.position.y and py < self.position.y + self.size.y
end

function Sidebar:rows()
  local round = self:get_round()
  local questions = bank.questions(round.id)
  local rows = {}
  if #questions == 0 then
    rows[1] = { kind = "empty", text = "No questions yet" }
    return rows
  end
  if not round.grouped then
    for _, question in ipairs(questions) do
      rows[#rows + 1] = { kind = "question", question = question, depth = 0 }
    end
    return rows
  end
  local order = { "Easy", "Medium", "Hard" }
  local groups = { Easy = {}, Medium = {}, Hard = {} }
  local extra = {}
  for _, question in ipairs(questions) do
    local bucket = groups[question.difficulty]
    if bucket then
      bucket[#bucket + 1] = question
    else
      extra[#extra + 1] = question
    end
  end
  for _, name in ipairs(order) do
    if #groups[name] > 0 then
      rows[#rows + 1] = { kind = "group", name = name, count = #groups[name] }
      if self.expanded[name] then
        for _, question in ipairs(groups[name]) do
          rows[#rows + 1] = { kind = "question", question = question, depth = 1 }
        end
      end
    end
  end
  for _, question in ipairs(extra) do
    rows[#rows + 1] = { kind = "question", question = question, depth = 0 }
  end
  return rows
end

function Sidebar:each_row()
  local rows = self:rows()
  local _, oy = self:get_content_offset()
  local x = self.position.x + self:tab_width()
  local y = oy
  local w = math.max(0, self.size.x - self:tab_width())
  local h = self:item_height()
  local i = 0
  return function()
    i = i + 1
    local row = rows[i]
    if not row then return nil end
    local top = y
    y = y + h
    return row, x, top, w, h
  end
end

function Sidebar:get_scrollable_size()
  return self:item_height() * (#self:rows() + 1)
end

function Sidebar:question_id(question)
  return self:get_round().id .. "-" .. question.slug
end

function Sidebar:row_key(row)
  if row.kind == "question" then return "q:" .. row.question.slug end
  if row.kind == "group" then return "g:" .. row.name end
  return "empty"
end

function Sidebar:draw_tabs()
  local width = self:tab_width()
  local height = self:tab_height()
  local x = self.position.x
  local y0 = self.position.y
  renderer.draw_rect(x, y0, width, self.size.y, style.background)
  self.tab_hits = {}
  for index, round in ipairs(bank.rounds) do
    local y = y0 + (index - 1) * height
    local active = index == self.round_index
    local hovered = self.hovered_tab == index
    if active or hovered then
      renderer.draw_rect(x, y, width, height, style.line_highlight)
    end
    if active then
      local mark = math.max(style.divider_size * 2, 2)
      renderer.draw_rect(x, y, mark, height, style.accent or style.text)
    end
    local color = (active or hovered) and style.text or style.dim
    common.draw_text(style.font, color, round.label, "center", x, y, width, height)
    self.tab_hits[index] = { x = x, y = y, w = width, h = height }
  end
  renderer.draw_rect(x + width - style.divider_size, y0, style.divider_size, self.size.y, style.divider)
end

function Sidebar:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local height = self:item_height()
  local list_x = self.position.x + self:tab_width()
  core.push_clip_rect(list_x, self.position.y, math.max(0, self.size.x - self:tab_width()), self.size.y)
  for row, x, y, w, h in self:each_row() do
    if y + h >= self.position.y and y < self.position.y + self.size.y then
      local hovered = self.hovered_key == self:row_key(row)
      local selected = row.kind == "question" and self.selected_id == self:question_id(row.question)
      local status_bg, title_color
      if row.kind == "question" then
        local status = memory.status(self:question_id(row.question))
        if status == "solved" then
          status_bg = (hovered or selected) and solved_hover or solved_bg
        elseif status == "attempted" then
          status_bg = (hovered or selected) and attempted_hover or attempted_bg
        end
        if status_bg then title_color = status_text end
      end
      if status_bg then
        renderer.draw_rect(x, y, w, height, status_bg)
      elseif hovered or selected then
        renderer.draw_rect(x, y, w, height, style.line_highlight)
      end
      local text_x = x + style.padding.x + (row.depth or 0) * style.padding.x
      if row.kind == "group" then
        local chevron = self.expanded[row.name] and "-" or "+"
        common.draw_text(style.icon_font, hovered and style.accent or style.text, chevron, nil, text_x, y, 0, h)
        text_x = text_x + style.icon_font:get_width("-") + style.padding.x
        common.draw_text(style.font, style.text, row.name .. "  " .. row.count, nil, text_x, y, 0, h)
      elseif row.kind == "empty" then
        common.draw_text(style.font, style.dim, row.text, nil, text_x, y, 0, h)
      else
        local color = title_color or ((hovered or selected) and style.accent or style.text)
        local title = row.question.title or row.question.slug
        common.draw_text(style.font, color, title, nil, text_x, y, 0, h)
      end
    end
  end
  core.pop_clip_rect()
  self:draw_tabs()
  self:draw_scrollbar()
end

function Sidebar:on_mouse_moved(px, py, ...)
  if Sidebar.super.on_mouse_moved(self, px, py, ...) then
    self.hovered_key = nil
    self.hovered_tab = nil
    return
  end
  self.hovered_key = nil
  self.hovered_tab = nil
  if self:in_tab_column(px, py) then
    for index, hit in ipairs(self.tab_hits) do
      if px >= hit.x and px < hit.x + hit.w and py >= hit.y and py < hit.y + hit.h then
        self.hovered_tab = index
        return
      end
    end
    return
  end
  for row, x, y, w, h in self:each_row() do
    if px >= x and px < x + w and py >= y and py < y + h then
      self.hovered_key = self:row_key(row)
      return
    end
  end
end

function Sidebar:on_mouse_pressed(button, px, py, clicks)
  if Sidebar.super.on_mouse_pressed(self, button, px, py, clicks) then
    return true
  end
  if self:in_tab_column(px, py) then
    for index, hit in ipairs(self.tab_hits) do
      if px >= hit.x and px < hit.x + hit.w and py >= hit.y and py < hit.y + hit.h then
        self.round_index = index
        self.scroll.to.y = 0
        core.redraw = true
        return true
      end
    end
    return true
  end
  local row
  for item, x, y, w, h in self:each_row() do
    if px >= x and px < x + w and py >= y and py < y + h then
      row = item
      break
    end
  end
  if not row then return true end
  if row.kind == "group" then
    self.expanded[row.name] = not self.expanded[row.name]
    core.redraw = true
  elseif row.kind == "question" then
    local session = require "plugins.prep.session"
    self.selected_id = self:question_id(row.question)
    session.open(self:get_round().id, row.question.slug)
  end
  return true
end

function Sidebar:refresh()
  core.redraw = true
end

function Sidebar:select_question(round, slug)
  for index, item in ipairs(bank.rounds) do
    if item.id == round then
      self.round_index = index
      break
    end
  end
  self.selected_id = round .. "-" .. slug
  core.redraw = true
end

return Sidebar
