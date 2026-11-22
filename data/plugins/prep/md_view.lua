-- mod-version:4
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"

local md = {}

local function blocked(doc)
  return doc.read_only and not doc._prep_write
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
end

local NamedView = DocView:extend()

function NamedView:new(doc, tab_name)
  NamedView.super.new(self, doc)
  self.tab_name = tab_name
end

function NamedView:get_name()
  return self.tab_name or NamedView.super.get_name(self)
end

function NamedView:try_close()
end

function md.load_file(doc, path, read_only)
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
end

---Create a document and a tab view. `path` is optional; when omitted the doc is memory-only.
function md.create(tab_name, text, read_only, path)
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
  return doc, NamedView(doc, tab_name)
end

md.NamedView = NamedView

return md
