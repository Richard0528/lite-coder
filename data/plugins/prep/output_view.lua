-- mod-version:4
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local util = require "plugins.prep.util"

local OutputView = View:extend()

function OutputView:__tostring() return "OutputView" end

function OutputView:new()
  OutputView.super.new(self)
  self.scrollable = true
  self.lines = {}
end

function OutputView:get_name()
  return "Output"
end

function OutputView:try_close()
end

function OutputView:clear()
  self.lines = {}
  self.scroll.to.y = 0
  self.scroll.y = 0
  core.redraw = true
end

-- Keep the newest MAX_LINES lines. Trimming waits until TRIM_SLACK extra lines
-- pile up, so a program that prints nonstop pays for a trim once per batch
-- instead of once per line.
local MAX_LINES = 4000
local TRIM_SLACK = 1000
local TRIM_NOTE = "(earlier output trimmed)"

function OutputView:add(text, kind)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then return end
  local start = 1
  while true do
    local newline = text:find("\n", start, true)
    local piece = newline and text:sub(start, newline - 1) or text:sub(start)
    if piece ~= "" or newline then
      self.lines[#self.lines + 1] = { text = piece, kind = kind or "out" }
    end
    if not newline then break end
    start = newline + 1
    if start > #text then break end
  end
  if #self.lines > MAX_LINES + TRIM_SLACK then
    local first = #self.lines - MAX_LINES + 1
    local kept = table.move(self.lines, first, #self.lines, 2, {})
    kept[1] = { text = TRIM_NOTE, kind = "meta" }
    self.lines = kept
  end
  core.redraw = true
end

function OutputView:get_text()
  local parts = {}
  for _, line in ipairs(self.lines) do
    parts[#parts + 1] = line.text
  end
  return table.concat(parts, "\n")
end

function OutputView:get_item_height()
  return style.code_font:get_height() + math.floor(style.padding.y / 2)
end

function OutputView:get_scrollable_size()
  return self:get_item_height() * (#self.lines + 1) + style.padding.y
end

function OutputView:scroll_to_end()
  local max_scroll = math.max(0, self:get_scrollable_size() - self.size.y)
  self.scroll.to.y = max_scroll
end

function OutputView:update()
  OutputView.super.update(self)
  if self.follow ~= false then
    self:scroll_to_end()
  end
end

function OutputView:on_mouse_pressed(...)
  self.follow = false
  return OutputView.super.on_mouse_pressed(self, ...)
end

function OutputView:draw()
  self:draw_background(style.background)
  local ox, oy = self:get_content_offset()
  local lh = self:get_item_height()
  local x = ox + style.padding.x
  local y = oy + style.padding.y
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for _, line in ipairs(self.lines) do
    if y + lh >= self.position.y and y < self.position.y + self.size.y then
      local color = style.text
      if line.kind == "err" then color = util.err()
      elseif line.kind == "meta" then color = style.dim end
      common.draw_text(style.code_font, color, line.text, nil, x, y, 0, lh)
    end
    y = y + lh
  end
  if #self.lines == 0 then
    common.draw_text(style.font, style.dim, "Output", nil, x, y, 0, style.font:get_height())
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

return OutputView
