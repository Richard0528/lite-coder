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
  self.no_close = true
  self.no_drag = true
end

function OutputView:get_name()
  return "Output"
end

function OutputView:try_close()
end

function OutputView:clear()
  self.lines = {}
  self._rows = nil
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
  self._rows = nil
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

function OutputView:text_width()
  local bar = style.expanded_scrollbar_size
  return math.max(style.code_font:get_width("M"), self.size.x - style.padding.x * 2 - bar)
end

function OutputView:ensure_layout()
  local width = self:text_width()
  if self._rows and self._layout_width == width and self._layout_n == #self.lines then
    return
  end
  local rows = {}
  local total = 0
  for i, line in ipairs(self.lines) do
    local wrapped = util.wrap(style.code_font, line.text, width)
    if #wrapped == 0 then wrapped = { "" } end
    rows[i] = wrapped
    total = total + #wrapped
  end
  self._rows = rows
  self._layout_width = width
  self._layout_n = #self.lines
  self._row_total = total
end

function OutputView:get_scrollable_size()
  self:ensure_layout()
  return self:get_item_height() * (self._row_total + 1) + style.padding.y
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
  self:ensure_layout()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for i, line in ipairs(self.lines) do
    local color = style.text
    if line.kind == "err" then color = util.err()
    elseif line.kind == "meta" then color = style.dim end
    for _, row in ipairs(self._rows[i]) do
      if y + lh >= self.position.y and y < self.position.y + self.size.y then
        common.draw_text(style.code_font, color, row, nil, x, y, 0, lh)
      end
      y = y + lh
    end
  end
  if #self.lines == 0 then
    common.draw_text(style.font, style.dim, "Output", nil, x, y, 0, style.font:get_height())
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

return OutputView
