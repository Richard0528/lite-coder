-- mod-version:4
local storage = require "core.storage"
local bank = require "plugins.prep.bank"
local memory = require "plugins.prep.memory"
local util = require "plugins.prep.util"

local quiz = {}
quiz.hits = {}
local cached_date
local cached_deck

local function rng_for(date)
  local n = 1
  for i = 1, #date do
    n = (n * 33 + date:byte(i)) % 2147483647
  end
  return function()
    n = (1103515245 * n + 12345) % 2147483647
    return n / 2147483647
  end
end

local function load_day(date)
  local saved = storage.load("prep_quiz", date)
  if type(saved) == "table" and saved.items then return saved end
  return nil
end

local function save_day(date, deck)
  storage.save("prep_quiz", date, deck)
  cached_date = date
  cached_deck = deck
end

local function build(date)
  local questions = bank.quiz()
  local rng = rng_for(date)
  local items = {}
  local used = {}
  local guard = 0
  while #items < 5 and #questions > 0 and guard < 40 do
    guard = guard + 1
    local index = math.floor(rng() * #questions) + 1
    local question = questions[index]
    local id = question and (question.id or tostring(index))
    if question and not used[id] then
      used[id] = true
      items[#items + 1] = { kind = "quiz", question = question }
    end
  end
  local due = memory.due_cards()
  local cards = {}
  for i = 1, math.min(2, #due) do
    cards[#cards + 1] = {
      kind = "card",
      id = due[i].id,
      index = due[i].index,
      front = due[i].card.front,
      back = due[i].card.back,
      title = due[i].title,
    }
  end
  if #items == 0 then
    items = cards
  else
    for i, card in ipairs(cards) do
      items[i] = card
    end
  end
  return {
    cursor = 1,
    revealed = false,
    picked = nil,
    items = items,
    completed = #items == 0,
  }
end

function quiz.deck()
  local date = util.today()
  if cached_deck and cached_date == date then return cached_deck end
  local saved = load_day(date)
  if not saved then
    saved = build(date)
    save_day(date, saved)
  end
  cached_date = date
  cached_deck = saved
  return saved
end

function quiz.current()
  local deck = quiz.deck()
  return deck, deck.items[deck.cursor]
end

function quiz.streak()
  local saved = storage.load("prep_quiz", "streak")
  if type(saved) ~= "table" then return 0 end
  return saved.count or 0
end

local function mark_complete(deck)
  if deck.completed then return end
  deck.completed = true
  local today = util.today()
  local streak = storage.load("prep_quiz", "streak")
  if type(streak) ~= "table" then streak = { count = 0, last = "" } end
  if streak.last ~= today then
    local yesterday = util.add_days(today, -1)
    if streak.last == yesterday then
      streak.count = (streak.count or 0) + 1
    else
      streak.count = 1
    end
    streak.last = today
    storage.save("prep_quiz", "streak", streak)
  end
end

function quiz.answer(choice)
  local deck, item = quiz.current()
  if not item or deck.completed then return false end
  if item.kind == "card" then
    if not deck.revealed then
      deck.revealed = true
      save_day(util.today(), deck)
      return true
    end
    if deck.picked then return false end
    if choice ~= 1 and choice ~= 2 then return false end
    memory.grade_card(item.id, item.index, choice == 1)
    deck.picked = choice
    save_day(util.today(), deck)
    return true
  end
  if deck.picked then return false end
  local choices = item.question.choices or {}
  if choice < 1 or choice > #choices then return false end
  deck.picked = choice
  deck.revealed = true
  save_day(util.today(), deck)
  return true
end

function quiz.next()
  local deck = quiz.deck()
  if not deck.picked and not (deck.items[deck.cursor] and deck.items[deck.cursor].kind == "card" and deck.revealed == false) then
    if not deck.picked then return false end
  end
  if not deck.picked then return false end
  if deck.cursor >= #deck.items then
    mark_complete(deck)
    save_day(util.today(), deck)
    return true
  end
  deck.cursor = deck.cursor + 1
  deck.picked = nil
  deck.revealed = false
  save_day(util.today(), deck)
  return true
end

return quiz
