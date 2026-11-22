-- mod-version:4
local core = require "core"
local config = require "core.config"
local json = require "plugins.prep.json"
local bank = require "plugins.prep.bank"
local secrets = require "plugins.prep.secrets"
local state = require "plugins.prep.state"
local util = require "plugins.prep.util"

local leetcode = {}
local syncing = false

local function dirname(path)
  return path:match("(.+)[/\\][^/\\]+$") or "."
end

local function open_url(url)
  if PLATFORM == "Mac OS X" then
    system.exec("open '" .. url .. "'")
  else
    system.exec("xdg-open '" .. url .. "'")
  end
end

local function output_line(text, kind)
  if state.output then
    state.output:add(text, kind or "meta")
  end
  util.log("%s", text)
end

function leetcode.parse_cookie(cookie)
  cookie = tostring(cookie or "")
  local session_id = cookie:match("LEETCODE_SESSION=(.-);") or cookie:match("LEETCODE_SESSION=(.+)$")
  local csrf = cookie:match("csrftoken=(.-);") or cookie:match("csrftoken=(.+)$")
  return session_id, csrf
end

function leetcode.verify(cookie, on_done)
  local session_id, csrf = leetcode.parse_cookie(cookie)
  if not session_id or session_id == "" then
    core.error("Cookie is missing LEETCODE_SESSION.")
    leetcode.login(on_done)
    return
  end
  core.add_thread(function()
    local body = json.encode({
      query = "query globalData { userStatus { username isSignedIn isPremium } }",
      variables = {},
    })
    local headers = {
      "Content-Type: application/json",
      "Origin: https://leetcode.com",
      "Referer: https://leetcode.com/",
      "X-Requested-With: XMLHttpRequest",
      "User-Agent: " .. util.user_agent(),
      "Cookie: " .. cookie,
    }
    if csrf and csrf ~= "" then
      headers[#headers + 1] = "X-CSRFToken: " .. csrf
    end
    local out, _, start_err = util.curl("https://leetcode.com/graphql", headers, body, 30)
    if not out then
      core.error("Could not check the cookie: %s", tostring(start_err))
      if on_done then on_done(false) end
      return
    end
    local ok, data = pcall(json.decode, out, 1, nil)
    local user = ok and data and data.data and data.data.userStatus
    if not user or not user.isSignedIn or not user.username or user.username == "" then
      core.error("LeetCode did not accept that cookie.")
      leetcode.login(on_done)
      return
    end
    secrets.update({ leetcode_cookie = cookie, leetcode_user = user.username })
    state.leetcode_user = user.username
    core.status_view:show_message("i", require("core.style").text, "Signed in as " .. user.username)
    core.redraw = true
    if on_done then on_done(true) end
  end)
end

function leetcode.login(on_done)
  core.nag_view:show(
    "LeetCode login required",
    "Log in in the browser, then paste the whole Cookie header from a leetcode.com request.\nDevTools, Network tab, Request Headers, Cookie. Keep cf_clearance in it.\nIf LeetCode still refuses, set config.plugins.prep.user_agent to your browser's User-Agent.\n",
    {
      { text = "Log in", default_yes = true },
      { text = "Cancel", default_no = true },
    },
    function(item)
      if not item or item.text ~= "Log in" then
        if on_done then on_done(false) end
        return
      end
      open_url("https://leetcode.com/accounts/login/")
      core.command_view:enter("Paste LeetCode Cookie", {
        submit = function(text)
          leetcode.verify(text or "", on_done)
        end,
        cancel = function()
          if on_done then on_done(false) end
        end,
      })
    end
  )
end

function leetcode.logout()
  secrets.update({ leetcode_cookie = "", leetcode_user = "" })
  state.leetcode_user = nil
  core.status_view:show_message("i", require("core.style").text, "Signed out of LeetCode")
  core.redraw = true
end

local function run_sync(on_done)
  local script = util.fetch_script()
  if not system.get_file_info(script) then
    core.error("Fetch script not found: %s", script)
    if on_done then on_done(1) end
    return
  end
  local python = config.plugins.prep.python or "python3"
  local cookie = secrets.leetcode_cookie()
  local out_dir = util.join(util.prep_dir(), "bank")
  util.ensure_dir(out_dir)
  local argv = { python, script, "--resume", "--out", out_dir }
  -- The cookie goes over stdin so it never sits in a file or an argument list.
  if cookie and cookie ~= "" then argv[#argv + 1] = "--cookie-stdin" end
  if state.output then
    state.output:clear()
    state.output.follow = true
  end
  local session = require "plugins.prep.session"
  session.show("Output")
  output_line("Syncing questions...")
  local proc, err = process.start(argv, {
    cwd = dirname(script),
    env = { LEETCODE_USER_AGENT = util.user_agent() },
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then
    core.error("Could not start the fetch script: %s", tostring(err))
    if on_done then on_done(1) end
    return
  end
  if cookie and cookie ~= "" then
    proc.stdin:write(cookie .. "\n")
  end
  proc.stdin:close()
  core.add_thread(function()
    util.stream_process(proc, {
      on_out = function(text) if state.output then state.output:add(text, "out") end end,
      on_err = function(text) if state.output then state.output:add(text, "err") end end,
    })
    local code = proc:returncode() or 0
    output_line("Sync finished (" .. tostring(code) .. ").")
    bank.reload()
    if state.sidebar then state.sidebar:refresh() end
    if on_done then on_done(code) end
  end)
end

function leetcode.sync()
  if syncing then
    core.error("A sync is already running.")
    return
  end
  syncing = true
  run_sync(function(code)
    syncing = false
    if code == 3 then
      leetcode.login(function(ok)
        if ok then leetcode.sync() end
      end)
    end
  end)
end

function leetcode.restore_user()
  local saved = secrets.load()
  if saved.leetcode_user and saved.leetcode_user ~= "" then
    state.leetcode_user = saved.leetcode_user
  end
end

return leetcode
