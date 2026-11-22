-- mod-version:4
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local command = require "core.command"
local View = require "core.view"
local state = require "plugins.prep.state"

local RunBar = View:extend()

function RunBar:__tostring() return "RunBar" end

function RunBar:new()
  RunBar.super.new(self)
  self.init_size = true
  self.hovered = nil
end

function RunBar:get_name()
  return "Run"
end

local function buttons()
  local session = state.session
  if not session then return {} end
  local round = session.question.round
  local items = {}
  if round == "coding" or round == "debug" then
    items[#items + 1] = { label = "Run", command = "prep:run" }
    if session.question.meta and session.question.examples and session.question.examples ~= "" then
      items[#items + 1] = { label = "Examples", command = "prep:run-examples" }
    end
    if session.running then
      items[#items + 1] = { label = "Stop", command = "prep:stop" }
    end
  end
  items[#items + 1] = { label = "Done", command = "prep:done" }
  items[#items + 1] = { label = "Ask", command = "prep:ask-ai" }
  return items
end

function RunBar:visible_height()
  if not state.session then return 0 end
  return style.font:get_height() + style.padding.y * 2
end

function RunBar:update()
  local dest = self:visible_height()
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  RunBar.super.update(self)
end

function RunBar:each_item()
  local height = style.font:get_height()
  local ox, oy = self:get_content_offset()
  local x = ox + style.padding.x
  local y = oy + style.padding.y
  local index = 0
  local list = buttons()
  return function()
    index = index + 1
    local item = list[index]
    if not item then return nil end
    local width = style.font:get_width(item.label) + style.padding.x * 2
    local left = x
    x = x + width + style.padding.x
    return item, left, y, width, height
  end
end

function RunBar:draw()
  if self.size.y < 1 or not state.session then return end
  self:draw_background(style.background2)
  renderer.draw_rect(self.position.x, self.position.y + self.size.y - style.divider_size, self.size.x, style.divider_size, style.divider)
  for item, x, y, w, h in self:each_item() do
    local active = item == self.hovered
    local color = active and style.text or style.dim
    if item.command == "prep:done" then color = active and style.text or (style.accent or style.text) end
    common.draw_text(style.font, color, item.label, "center", x, y, w, h)
  end
end

function RunBar:on_mouse_moved(px, py, ...)
  RunBar.super.on_mouse_moved(self, px, py, ...)
  self.hovered = nil
  for item, x, y, w, h in self:each_item() do
    if px >= x and px < x + w and py >= y and py < y + h then
      self.hovered = item
      return
    end
  end
end

function RunBar:on_mouse_pressed(button, px, py, clicks)
  if RunBar.super.on_mouse_pressed(self, button, px, py, clicks) then
    return true
  end
  local item = self.hovered
  if item then
    -- Hand focus back before running the command, as the toolbar does. Shortcuts
    -- and typing keep working, and commands that open a prompt still take focus.
    core.set_active_view(self:focus_target())
    if command.is_valid(item.command) then
      command.perform(item.command)
    end
  end
  return true
end

function RunBar:focus_target()
  local last = core.last_active_view
  if last and last ~= self and last ~= state.sidebar and last ~= core.command_view then
    return last
  end
  local session = state.session
  if session and session.solution_doc then
    local views = core.get_views_referencing_doc(session.solution_doc)
    if views[1] then return views[1] end
  end
  return core.root_view:get_primary_node().active_view
end

return RunBar
