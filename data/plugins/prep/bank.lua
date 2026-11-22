-- mod-version:4
local json = require "plugins.prep.json"
local util = require "plugins.prep.util"

local bank = {}

bank.rounds = {
  { id = "coding", label = "Code", grouped = true },
  { id = "design", label = "Design", grouped = false },
  { id = "debug", label = "Debug", grouped = true },
  { id = "explain", label = "Explain", grouped = false },
}

local index_cache
local question_cache = {}
local curated_cache = {}

local function decode(path)
  local text = util.read_file(path)
  if not text or text == "" then return nil end
  local ok, value = pcall(json.decode, text, 1, nil)
  if ok and type(value) == "table" then return value end
  return nil
end

local function curated_map(round)
  if curated_cache[round] then return curated_cache[round] end
  local list = decode(util.join(util.plugin_dir(), "curated" .. PATHSEP .. round .. ".json")) or {}
  local map = {}
  for _, question in ipairs(list) do
    if question.slug then
      question.round = question.round or round
      map[question.slug] = question
    end
  end
  curated_cache[round] = map
  return map
end

local function generated_root()
  -- Synced questions live in the user directory. A bank next to the plugin
  -- is only a fallback for a checkout where the fetch script was run by hand.
  local candidates = {
    util.join(util.prep_dir(), "bank"),
    util.join(util.plugin_dir(), "bank"),
  }
  for _, root in ipairs(candidates) do
    if system.get_file_info(util.join(root, "index.json")) then
      return root
    end
  end
  return nil
end

function bank.root()
  return generated_root()
end

function bank.reload()
  index_cache = nil
  question_cache = {}
  curated_cache = {}
end

local function index_from_curated()
  local index = {}
  for _, round in ipairs(bank.rounds) do
    local rows = {}
    for _, question in pairs(curated_map(round.id)) do
      rows[#rows + 1] = {
        slug = question.slug,
        title = question.title,
        difficulty = question.difficulty,
        id = question.frontend_id,
      }
    end
    table.sort(rows, function(a, b)
      return (a.title or "") < (b.title or "")
    end)
    index[round.id] = rows
  end
  return index
end

function bank.index()
  if index_cache then return index_cache end
  local root = generated_root()
  index_cache = (root and decode(util.join(root, "index.json"))) or index_from_curated()
  for _, round in ipairs(bank.rounds) do
    index_cache[round.id] = index_cache[round.id] or {}
  end
  return index_cache
end

function bank.questions(round)
  return bank.index()[round] or {}
end

function bank.get(round, slug)
  local key = round .. "/" .. slug
  if question_cache[key] then return question_cache[key] end
  local question
  local root = generated_root()
  if root then
    question = decode(root .. PATHSEP .. round .. PATHSEP .. slug .. ".json")
  end
  if not question then
    question = curated_map(round)[slug]
  end
  if question then
    question.round = question.round or round
    question.slug = question.slug or slug
  end
  question_cache[key] = question
  return question
end

function bank.quiz()
  local root = generated_root()
  local from_bank = root and decode(util.join(root, "quiz.json"))
  if type(from_bank) == "table" and #from_bank > 0 then return from_bank end
  return decode(util.join(util.plugin_dir(), "curated" .. PATHSEP .. "quiz.json")) or {}
end

function bank.find_meta(round, slug)
  for _, row in ipairs(bank.questions(round)) do
    if row.slug == slug then return row end
  end
  return { slug = slug, round = round }
end

return bank
