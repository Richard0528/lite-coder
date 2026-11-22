-- mod-version:4
local core = require "core"
local config = require "core.config"
local json = require "plugins.prep.json"
local secrets = require "plugins.prep.secrets"
local util = require "plugins.prep.util"

local llm = {}

local function settings()
  return config.plugins.prep.llm
end

local function request_key(on_done)
  if core.active_view == core.command_view then
    core.error("Close the command prompt, then try again.")
    on_done(false)
    return
  end
  core.command_view:enter("OpenAI API key", {
    text = "",
    submit = function(text)
      text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if text == "" then
        on_done(false)
        return
      end
      secrets.update({ api_key = text })
      on_done(true)
    end,
    cancel = function()
      on_done(false)
    end,
    validate = function(text)
      return text ~= nil
    end,
  })
end

local function run_request(messages, temperature, on_done)
  local cfg = settings()
  local key = secrets.api_key()
  if not key then
    on_done("No API key. Set " .. (cfg.api_key_env or "OPENAI_API_KEY") .. " or save one when asked.")
    return
  end
  core.add_thread(function()
    local body = json.encode({
      model = cfg.model,
      messages = messages,
      temperature = temperature or 0.2,
    })
    local url = (cfg.base_url or ""):gsub("/+$", "") .. "/chat/completions"
    local out, err_text, start_err = util.curl(url, {
      "Content-Type: application/json",
      "Authorization: Bearer " .. key,
    }, body, 90)
    if not out then
      on_done(start_err)
      return
    end
    local decoded, data = pcall(json.decode, out, 1, nil)
    if not decoded or type(data) ~= "table" or not data.choices or not data.choices[1] then
      local message = err_text
      if message == "" then message = out end
      if type(data) == "table" and data.error and data.error.message then
        message = data.error.message
      end
      on_done(util.clip(message, 400))
      return
    end
    local content = data.choices[1].message and data.choices[1].message.content or ""
    on_done(nil, content)
  end)
end

function llm.complete(messages, on_done, temperature)
  if not secrets.api_key() then
    request_key(function(ok)
      if not ok then
        on_done("No API key.")
        return
      end
      run_request(messages, temperature, on_done)
    end)
    return
  end
  run_request(messages, temperature, on_done)
end

function llm.extract_json(text)
  if not text then return nil end
  local fenced = text:match("```json%s*(.-)```") or text:match("```%s*(.-)```")
  local raw = fenced or text
  local start_at = raw:find("{", 1, true)
  local finish_at = nil
  if start_at then
    for i = #raw, start_at, -1 do
      if raw:byte(i) == string.byte("}") then
        finish_at = i
        break
      end
    end
  end
  if not start_at or not finish_at then return nil, text end
  local slice = raw:sub(start_at, finish_at)
  local ok, value = pcall(json.decode, slice, 1, nil)
  if ok and type(value) == "table" then return value end
  return nil, text
end

return llm
