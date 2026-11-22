-- mod-version:4
local common = require "core.common"
local config = require "core.config"
local util = require "plugins.prep.util"

local secrets = {}

local function path()
  return util.join(util.prep_dir(), "secrets.lua")
end

function secrets.load()
  local file = path()
  if not system.get_file_info(file) then return {} end
  local chunk, err = loadfile(file)
  if not chunk then
    return {}
  end
  local ok, data = pcall(chunk)
  if ok and type(data) == "table" then return data end
  return {}
end

function secrets.save(data)
  local ok = util.write_private(path(), "return " .. common.serialize(data) .. "\n")
  return ok and true or false
end

function secrets.update(patch)
  local data = secrets.load()
  for key, value in pairs(patch) do
    data[key] = value
  end
  secrets.save(data)
  return data
end

function secrets.api_key()
  local llm = config.plugins.prep.llm or {}
  local env_name = llm.api_key_env or "OPENAI_API_KEY"
  local env = os.getenv(env_name)
  if env and env ~= "" then return env end
  local saved = secrets.load().api_key
  if saved and saved ~= "" then return saved end
  return nil
end

function secrets.leetcode_cookie()
  local env = os.getenv("LEETCODE_COOKIE")
  if env and env ~= "" then return env end
  local saved = secrets.load().leetcode_cookie
  if saved and saved ~= "" then return saved end
  return nil
end

return secrets
