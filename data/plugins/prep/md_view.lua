-- mod-version:4
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"

local md = {}

local function blocked(doc)
  return doc.read_only and not doc._prep_write
end

local function wrapping_views(doc)
  local found = {}
  if not doc or not core.root_view or not core.root_view.root_node then return found end
  for _, view in ipairs(core.get_views_referencing_doc(doc)) do
    if view.wrapping_enabled then
      found[#found + 1] = view
    end
  end
  return found
end

-- Line wrapping tracks breaks from insert and remove. Replacing doc.lines
-- directly, which load and set_text both do, skips that. Drop the cache
-- around the edit, then rebuild it from the text that is left.
local function suspend_wrap(doc)
  local views = wrapping_views(doc)
  for _, view in ipairs(views) do
    view.wrapped_settings = nil
  end
  return views
end

local function resume_wrap(views)
  local LineWrapping = package.loaded["plugins.linewrapping"]
  if not LineWrapping then return end
  for _, view in ipairs(views) do
    view.wrapped_settings = nil
    LineWrapping.update_docview_breaks(view)
  end
end

local original_save = Doc.save
function Doc:save(...)
  if self.read_only then return end
  return original_save(self, ...)
end

local guarded = {
  "insert", "remove", "text_input", "undo", "redo",
  "delete_to", "delete_to_cursor", "indent_text", "ime_text_editing", "replace",
}
for _, name in ipairs(guarded) do
  local original = Doc[name]
  Doc[name] = function(self, ...)
    if blocked(self) then return end
    return original(self, ...)
  end
end

function md.set_text(doc, text)
  text = text or ""
  if text:sub(-1) == "\n" then text = text:sub(1, -2) end
  local views = suspend_wrap(doc)
  doc._prep_write = true
  local last = #doc.lines
  doc:remove(1, 1, last, #doc.lines[last])
  if #doc.lines ~= 1 or doc.lines[1] ~= "\n" then
    doc.lines = { "\n" }
    doc.highlighter:soft_reset()
  end
  if text ~= "" then
    doc:insert(1, 1, text)
  end
  doc:clean()
  doc._prep_write = false
  resume_wrap(views)
end

local fonts
local font_scale

local function text_font(kind, base)
  if kind == "code" then return fonts.code end
  if kind == "bold" then return fonts.bold end
  if kind == "italic" then return fonts.italic end
  return base or fonts.body
end

local function ensure_fonts()
  if fonts and font_scale == SCALE then return end
  font_scale = SCALE
  local function copy(font, size, attrs)
    local ok, copied = pcall(font.copy, font, size or font:get_size(), attrs or {})
    if ok and copied then return copied end
    return font
  end
  fonts = {
    body = style.font,
    h1 = copy(style.font, 22 * SCALE),
    h2 = copy(style.font, 18 * SCALE),
    h3 = copy(style.font, 16 * SCALE),
    bold = copy(style.font, nil, { bold = true }),
    italic = copy(style.font, nil, { italic = true }),
    code = style.code_font,
  }
end

local function parse_inline(text)
  local spans = {}
  local buf = ""
  local i = 1
  local n = #text
  local function flush()
    if buf == "" then return end
    spans[#spans + 1] = { kind = "text", text = buf }
    buf = ""
  end
  while i <= n do
    local two = text:sub(i, i + 1)
    local one = text:sub(i, i)
    if one == "`" then
      local close = text:find("`", i + 1, true)
      if close and close > i + 1 then
        flush()
        spans[#spans + 1] = { kind = "code", text = text:sub(i + 1, close - 1) }
        i = close + 1
      else
        buf = buf .. one
        i = i + 1
      end
    elseif two == "**" then
      local close = text:find("**", i + 2, true)
      if close and close > i + 2 then
        flush()
        spans[#spans + 1] = { kind = "bold", text = text:sub(i + 2, close - 1) }
        i = close + 2
      else
        buf = buf .. two
        i = i + 2
      end
    elseif one == "*" then
      local close = text:find("*", i + 1, true)
      if close and close > i + 1 then
        flush()
        spans[#spans + 1] = { kind = "italic", text = text:sub(i + 1, close - 1) }
        i = close + 1
      else
        buf = buf .. one
        i = i + 1
      end
    else
      buf = buf .. one
      i = i + 1
    end
  end
  flush()
  if #spans == 0 then spans[1] = { kind = "text", text = "" } end
  return spans
end

local function wrap_spans(spans, base, max_width)
  local rows = {}
  local pieces = {}
  local text = ""
  local width = 0
  local function commit()
    if #pieces == 0 then return end
    rows[#rows + 1] = { pieces = pieces, text = text }
    pieces = {}
    text = ""
    width = 0
  end
  local function add(kind, chunk)
    if chunk == "" then return end
    local font = text_font(kind, base)
    local w = font:get_width(chunk)
    local last = pieces[#pieces]
    if last and last.kind == kind then
      last.text = last.text .. chunk
      last.w = last.w + w
    else
      pieces[#pieces + 1] = { kind = kind, text = chunk, font = font, w = w }
    end
    text = text .. chunk
    width = width + w
  end
  local function add_words(kind, chunk)
    local font = text_font(kind, base)
    local pos = 1
    local function take(pattern)
      local start, finish = chunk:find(pattern, pos)
      if start ~= pos then return nil end
      return chunk:sub(start, finish)
    end
    while pos <= #chunk do
      local space = take("%s+")
      if space then
        if width > 0 and width + font:get_width(space) <= max_width then
          add(kind, space)
        elseif width > 0 then
          commit()
        end
        pos = pos + #space
      else
        local word = take("%S+")
        if not word then break end
        local word_width = font:get_width(word)
        if width > 0 and width + word_width > max_width then commit() end
        if word_width <= max_width then
          add(kind, word)
        else
          local acc = ""
          for char in common.utf8_chars(word) do
            local trial = acc .. char
            if acc ~= "" and font:get_width(trial) > max_width then
              add(kind, acc)
              commit()
              acc = char
            else
              acc = trial
            end
          end
          if acc ~= "" then add(kind, acc) end
        end
        pos = pos + #word
      end
    end
  end
  for _, span in ipairs(spans) do
    add_words(span.kind, span.text)
  end
  commit()
  return rows
end

local function is_fence(line) return line:match("^%s*```") ~= nil end
local function is_heading(line) return line:match("^#+%s+%S") ~= nil end
local function is_list(line)
  return line:match("^%s*[%-%+%*]%s+%S") ~= nil or line:match("^%s*%d+[%.%)]%s+%S") ~= nil
end
local function is_quote(line) return line:match("^%s*>") ~= nil end
local function is_special(line)
  return is_fence(line) or is_heading(line) or is_list(line) or is_quote(line)
end

local MarkdownView = View:extend()

function MarkdownView:new(doc, tab_name)
  MarkdownView.super.new(self)
  self.scrollable = true
  self.doc = doc
  self.tab_name = tab_name
  self.no_close = true
  self.no_drag = true
  self.cursor = "ibeam"
  self.items = {}
  self.content_height = 0
end

function MarkdownView:get_name()
  return self.tab_name or "Markdown"
end

function MarkdownView:try_close()
end

function MarkdownView:text_width()
  local bar = style.expanded_scrollbar_size
  return math.max(style.font:get_width("M") * 8, self.size.x - style.padding.x * 2 - bar)
end

function MarkdownView:ensure_layout()
  ensure_fonts()
  local width = self:text_width()
  local change = self.doc:get_change_id()
  if change == self.layout_id and width == self.layout_width and self.layout_scale == SCALE then
    return
  end
  local source = {}
  for index, line in ipairs(self.doc.lines) do
    source[index] = line:gsub("\n$", "")
  end
  local items = {}
  local y = style.padding.y
  local gap = style.padding.y
  local function push(rows, opts)
    if #rows == 0 then return end
    local font = opts.font or fonts.body
    local h = font:get_height()
    for _, row in ipairs(rows) do
      items[#items + 1] = {
        kind = "text",
        y = y,
        h = h,
        pieces = row.pieces,
        text = row.text,
        indent = opts.indent or 0,
        shade = opts.shade,
        quote = opts.quote,
      }
      y = y + h
    end
    y = y + (opts.gap or gap)
  end
  local i = 1
  while i <= #source do
    local line = source[i]
    if line:match("^%s*$") then
      i = i + 1
    elseif is_fence(line) then
      local body = {}
      i = i + 1
      while i <= #source and not is_fence(source[i]) do
        body[#body + 1] = source[i]
        i = i + 1
      end
      if i <= #source then i = i + 1 end
      local rows = {}
      for _, code_line in ipairs(body) do
        local wrapped = wrap_spans({ { kind = "code", text = code_line == "" and " " or code_line } }, fonts.code, width - style.padding.x)
        for _, row in ipairs(wrapped) do rows[#rows + 1] = row end
        if #wrapped == 0 then rows[#rows + 1] = { pieces = {}, text = "" } end
      end
      if #rows == 0 then rows[1] = { pieces = {}, text = "" } end
      push(rows, { font = fonts.code, shade = "code", indent = style.padding.x / 2, gap = gap })
    elseif is_heading(line) then
      local marks, title = line:match("^(#+)%s+(.*)$")
      local level = math.min(#marks, 3)
      local font = level == 1 and fonts.h1 or (level == 2 and fonts.h2 or fonts.h3)
      local spans = parse_inline(title)
      for _, span in ipairs(spans) do
        if span.kind ~= "code" then span.kind = "text" end
      end
      push(wrap_spans(spans, font, width), { font = font, gap = gap })
      i = i + 1
    elseif is_list(line) then
      while i <= #source and is_list(source[i]) do
        local indent, marker, body = source[i]:match("^(%s*)([%-%+%*])%s+(.*)$")
        if not body then
          indent, marker, body = source[i]:match("^(%s*)(%d+[%.%)])%s+(.*)$")
        end
        if marker == "-" or marker == "+" or marker == "*" then marker = "•" end
        local nest = math.floor(#(indent or "") / 2) * style.padding.x
        local bullet = (marker or "•") .. " "
        local bullet_w = fonts.body:get_width(bullet)
        local rows = wrap_spans(parse_inline(body or ""), fonts.body, math.max(fonts.body:get_width("M") * 4, width - nest - bullet_w))
        if rows[1] then
          table.insert(rows[1].pieces, 1, { kind = "text", text = bullet, font = fonts.body, w = bullet_w })
          rows[1].text = bullet .. rows[1].text
        end
        local start = #items + 1
        push(rows, { indent = nest, gap = math.floor(style.padding.y / 3) })
        for index = start + 1, #items do
          items[index].indent = nest + bullet_w
        end
        i = i + 1
      end
      y = y + math.floor(gap / 2)
    elseif is_quote(line) then
      local parts = {}
      while i <= #source and is_quote(source[i]) do
        parts[#parts + 1] = source[i]:gsub("^%s*>%s?", "")
        i = i + 1
      end
      push(wrap_spans(parse_inline(table.concat(parts, " ")), fonts.body, width - style.padding.x), {
        indent = style.padding.x,
        quote = true,
      })
    else
      local parts = {}
      while i <= #source and source[i] ~= "" and not is_special(source[i]) do
        parts[#parts + 1] = source[i]
        i = i + 1
      end
      push(wrap_spans(parse_inline(table.concat(parts, " ")), fonts.body, width), {})
    end
  end
  self.items = items
  self.content_height = y + style.padding.y
  self.layout_id = change
  self.layout_width = width
  self.layout_scale = SCALE
  self.selection = nil
end

function MarkdownView:get_scrollable_size()
  self:ensure_layout()
  return self.content_height
end

function MarkdownView:hit(px, py)
  self:ensure_layout()
  local _, oy = self:get_content_offset()
  local left = self.position.x + style.padding.x
  local last_row, last_col = 1, 1
  for index, item in ipairs(self.items) do
    if item.kind == "text" then
      local sy = oy + item.y
      last_row = index
      last_col = #item.text + 1
      if py >= sy and py < sy + item.h then
        local x = left + (item.indent or 0)
        local col = 1
        if px <= x then return index, 1 end
        for _, piece in ipairs(item.pieces) do
          if px < x + piece.w then
            local acc = ""
            for char in common.utf8_chars(piece.text) do
              if x + piece.font:get_width(acc .. char) > px then
                return index, col + #acc
              end
              acc = acc .. char
            end
            return index, col + #piece.text
          end
          x = x + piece.w
          col = col + #piece.text
        end
        return index, col
      end
    end
  end
  return last_row, last_col
end

local function span_x(item, col)
  local seen = 0
  local x = 0
  local target = math.max(0, col - 1)
  for _, piece in ipairs(item.pieces) do
    local len = #piece.text
    if seen + len >= target then
      return x + piece.font:get_width(piece.text:sub(1, target - seen))
    end
    seen = seen + len
    x = x + piece.w
  end
  return x
end

function MarkdownView:selected_text()
  local sel = self.selection
  if not sel then return "" end
  local r1, c1, r2, c2 = sel[1], sel[2], sel[3], sel[4]
  if r1 > r2 or (r1 == r2 and c1 > c2) then
    r1, c1, r2, c2 = r2, c2, r1, c1
  end
  if r1 == r2 and c1 == c2 then return "" end
  local parts = {}
  for index = r1, r2 do
    local item = self.items[index]
    if item and item.text then
      local from = index == r1 and c1 or 1
      local to = index == r2 and (c2 - 1) or #item.text
      parts[#parts + 1] = to >= from and item.text:sub(from, to) or ""
    end
  end
  return table.concat(parts, "\n")
end

function MarkdownView:copy_selection()
  local text = self:selected_text()
  if text ~= "" then system.set_clipboard(text) end
end

function MarkdownView:draw()
  self:ensure_layout()
  self:draw_background(style.background)
  local _, oy = self:get_content_offset()
  local left = self.position.x + style.padding.x
  local top = self.position.y
  local bottom = top + self.size.y
  local sel = self.selection
  local r1, c1, r2, c2
  if sel then
    r1, c1, r2, c2 = sel[1], sel[2], sel[3], sel[4]
    if r1 > r2 or (r1 == r2 and c1 > c2) then
      r1, c1, r2, c2 = r2, c2, r1, c1
    end
  end
  for index, item in ipairs(self.items) do
    local sy = oy + item.y
    if sy + item.h >= top and sy < bottom then
      local x = left + (item.indent or 0)
      if item.shade == "code" then
        local pad = math.floor(style.padding.x / 2)
        renderer.draw_rect(x - pad, sy, self:text_width() - (item.indent or 0) + pad, item.h, style.background2)
      end
      if item.quote then
        renderer.draw_rect(x - math.floor(style.padding.x / 2), sy, math.max(2, style.divider_size * 2), item.h, style.dim)
      end
      if sel and index >= r1 and index <= r2 and not (r1 == r2 and c1 == c2) then
        local from = index == r1 and c1 or 1
        local to = index == r2 and c2 or (#item.text + 1)
        local x1 = x + span_x(item, from)
        local x2 = x + span_x(item, to)
        if x2 > x1 then
          renderer.draw_rect(x1, sy, x2 - x1, item.h, style.selection)
        end
      end
      local tx = x
      for _, piece in ipairs(item.pieces) do
        local color = style.syntax["normal"] or style.text
        if piece.kind == "code" then color = style.syntax["string"] or color end
        renderer.draw_text(piece.font, piece.text, tx, sy, color)
        tx = tx + piece.w
      end
    end
  end
  self:draw_scrollbar()
end

function MarkdownView:on_mouse_pressed(button, px, py, clicks)
  if MarkdownView.super.on_mouse_pressed(self, button, px, py, clicks) then
    return true
  end
  if button ~= "left" then return false end
  local row, col = self:hit(px, py)
  self.selection = { row, col, row, col }
  self.selecting = true
  core.redraw = true
  return true
end

function MarkdownView:on_mouse_moved(px, py, dx, dy)
  if self.selecting then
    local row, col = self:hit(px, py)
    self.selection[3], self.selection[4] = row, col
    core.redraw = true
    return
  end
  MarkdownView.super.on_mouse_moved(self, px, py, dx, dy)
end

function MarkdownView:on_mouse_released(button, px, py)
  self.selecting = false
  MarkdownView.super.on_mouse_released(self, button, px, py)
end

function MarkdownView:on_context_menu()
  return { items = {
    { text = "Copy", command = "prep:copy-markdown" },
  } }
end

local NamedView = DocView:extend()

function NamedView:new(doc, tab_name)
  NamedView.super.new(self, doc)
  self.tab_name = tab_name
  self.no_close = true
  self.no_drag = true
  self.font = "font"
end

function NamedView:get_name()
  return self.tab_name or NamedView.super.get_name(self)
end

function NamedView:get_gutter_width()
  return style.padding.x
end

function NamedView:draw_line_gutter()
  return self:get_line_height()
end

function NamedView:try_close()
end

function md.load_file(doc, path, read_only)
  local views = suspend_wrap(doc)
  doc.read_only = false
  doc._prep_write = true
  doc:set_filename(path, path)
  if system.get_file_info(path) then
    doc:load(path)
    doc:clean()
  else
    md.set_text(doc, "")
  end
  doc._prep_write = false
  doc.read_only = read_only and true or false
  doc.new_file = false
  resume_wrap(views)
end

---Create a document and a tab view. `path` is optional; when omitted the doc is memory-only.
---`rendered` shows the document as formatted markdown instead of source.
function md.create(tab_name, text, read_only, path, rendered)
  local doc
  if path and system.get_file_info(path) then
    doc = Doc(path, path, false)
  elseif path then
    doc = Doc(path, path, true)
  else
    doc = Doc()
    -- A relative filename makes Doc:reset_syntax read core.project_dir, which
    -- this version of Lite XL does not set. Keep the name local until a real
    -- absolute path exists.
    doc.filename = tab_name .. ".md"
  end
  if text ~= nil and not (path and system.get_file_info(path)) then
    md.set_text(doc, text)
  end
  doc.read_only = read_only and true or false
  doc:clean()
  table.insert(core.docs, doc)
  local view = rendered and MarkdownView(doc, tab_name) or NamedView(doc, tab_name)
  return doc, view
end

command.add(function()
  local view = core.active_view
  return view and view.copy_selection ~= nil, view
end, {
  ["prep:copy-markdown"] = function(view)
    view:copy_selection()
  end,
})

local mod = PLATFORM == "Mac OS X" and "cmd" or "ctrl"
keymap.add_direct({
  [mod .. "+c"] = {
    function()
      local view = core.active_view
      if not view or not view.copy_selection then return false end
      view:copy_selection()
    end,
    "doc:copy",
  },
})

md.NamedView = NamedView
md.MarkdownView = MarkdownView

return md
