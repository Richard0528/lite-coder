-- mod-version:4
local storage = require "core.storage"
local util = require "plugins.prep.util"

local memory = {}
local MODULE = "prep_memory"
local MAX_SESSIONS = 5
local MAX_CARDS = 4
local index_cache

local function question_id(question)
  return question.round .. "-" .. question.slug
end

function memory.index()
  if index_cache then return index_cache end
  local idx = storage.load(MODULE, "_index")
  if type(idx) ~= "table" then idx = {} end
  index_cache = idx
  return idx
end

local function save_index(idx)
  index_cache = idx
  storage.save(MODULE, "_index", idx)
end

function memory.status(id)
  local entry = memory.index()[id]
  return entry and entry.status or "new"
end

function memory.get(id)
  local rec = storage.load(MODULE, id)
  if type(rec) ~= "table" then return nil end
  return rec
end

function memory.touch(question)
  local id = question_id(question)
  local idx = memory.index()
  local entry = idx[id] or {
    status = "new",
    title = question.title,
    round = question.round,
  }
  entry.last_seen = util.now()
  entry.title = question.title or entry.title
  entry.round = question.round
  idx[id] = entry
  save_index(idx)
end

function memory.record_review(question, review)
  local id = question_id(question)
  local rec = memory.get(id) or {
    id = id,
    title = question.title,
    round = question.round,
    difficulty = question.difficulty,
    status = "new",
    attempts = 0,
    sessions = {},
    cards = {},
  }
  rec.attempts = (rec.attempts or 0) + 1
  rec.last_seen = util.now()
  rec.title = question.title or rec.title
  rec.difficulty = question.difficulty or rec.difficulty
  rec.round = question.round

  local verdict = review.verdict
  if verdict ~= "solved" and verdict ~= "partial" and verdict ~= "unsolved" then
    verdict = "attempted"
  end
  if verdict == "solved" then
    rec.status = "solved"
  elseif rec.status ~= "solved" then
    rec.status = "attempted"
  end

  table.insert(rec.sessions, 1, {
    date = util.today(),
    verdict = verdict,
    summary = util.clip(review.summary, 240),
    missing = util.clip(review.missing_piece or review.missing, 160),
  })
  while #rec.sessions > MAX_SESSIONS do
    table.remove(rec.sessions)
  end

  for _, card in ipairs(review.cards or {}) do
    if type(card) == "table" and card.front and card.back and card.front ~= "" then
      table.insert(rec.cards, 1, {
        front = util.clip(card.front, 160),
        back = util.clip(card.back, 200),
        box = 1,
        due = util.today(),
      })
    end
  end
  while #rec.cards > MAX_CARDS do
    table.remove(rec.cards)
  end

  storage.save(MODULE, id, rec)
  local idx = memory.index()
  idx[id] = {
    status = rec.status,
    last_seen = rec.last_seen,
    title = rec.title,
    round = rec.round,
    difficulty = rec.difficulty,
  }
  save_index(idx)
  return rec
end

function memory.summaries(question)
  local rec = memory.get(question_id(question))
  if not rec then return {} end
  return rec.sessions or {}
end

function memory.due_cards()
  local today = util.today()
  local cards = {}
  for id in pairs(memory.index()) do
    local rec = memory.get(id)
    if rec and rec.cards then
      for index, card in ipairs(rec.cards) do
        if (card.due or "") <= today then
          cards[#cards + 1] = {
            id = id,
            index = index,
            card = card,
            title = rec.title,
          }
        end
      end
    end
  end
  return cards
end

function memory.grade_card(id, index, correct)
  local rec = memory.get(id)
  if not rec or not rec.cards or not rec.cards[index] then return end
  local card = rec.cards[index]
  if correct then
    card.box = math.min((card.box or 1) + 1, 3)
  else
    card.box = 1
  end
  local gaps = { 1, 3, 7 }
  card.due = util.add_days(util.today(), gaps[card.box] or 7)
  storage.save(MODULE, id, rec)
end

function memory.stats()
  local solved, attempted = 0, 0
  local latest_date, latest
  for id, meta in pairs(memory.index()) do
    if meta.status == "solved" then
      solved = solved + 1
    elseif meta.status == "attempted" then
      attempted = attempted + 1
    end
    if meta.last_seen and (not latest_date or meta.last_seen > latest_date) then
      latest_date = meta.last_seen
      latest = { id = id, meta = meta }
    end
  end
  return {
    solved = solved,
    attempted = attempted,
    last = latest,
  }
end

return memory
