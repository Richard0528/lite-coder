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

local function output_line(text, kind)
  if state.output then
    state.output:add(text, kind or "meta")
  end
  util.log("%s", text)
end

---The newest progress line, shown on the status bar while a sync is running.
local function note_progress(text)
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      state.sync_status = util.clip(line, 96)
      core.redraw = true
    end
  end
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
    if on_done then on_done(false) end
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
      if on_done then on_done(false) end
      return
    end
    secrets.update({ leetcode_cookie = cookie, leetcode_user = user.username })
    state.leetcode_user = user.username
    core.status_view:show_message("i", require("core.style").text, "Signed in as " .. user.username)
    core.redraw = true
    if on_done then on_done(true) end
  end)
end

local logging_in = false

function leetcode.capture(on_done)
  if logging_in then
    core.error("A LeetCode login is already in progress.")
    return
  end
  local script = util.prep_script("leetcode_browser.py")
  if not system.get_file_info(script) then
    core.error("Login helper not found: %s", script)
    return
  end
  local python = config.plugins.prep.python or "python3"
  local profile = util.join(util.prep_dir(), "chrome-profile")
  util.ensure_dir(profile)
  local proc, err = process.start({
    python, script,
    "--profile", profile,
    "--timeout", "180",
  }, {
    env = util.runtime_env({ python }),
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then
    core.error("Could not open the login browser: %s", tostring(err))
    return
  end
  logging_in = true
  state.leetcode_busy = true
  core.redraw = true
  if state.output then
    state.output:add("Opening LeetCode so you can sign in...", "meta")
  end
  core.add_thread(function()
    local cookie
    util.stream_process(proc, {
      timeout = 200,
      on_out = function(text)
        for line in (text .. "\n"):gmatch("(.-)\n") do
          if line:sub(1, 7) == "COOKIE " then
            cookie = line:sub(8)
          elseif line ~= "" and state.output then
            state.output:add(line, "meta")
          end
        end
      end,
      on_err = function(text)
        if state.output and text ~= "" then state.output:add(text, "meta") end
      end,
    })
    logging_in = false
    state.leetcode_busy = false
    if cookie and cookie ~= "" then
      leetcode.verify(cookie, function(ok)
        if ok then core.status_view:show_message("i", require("core.style").text, "LeetCode cookie saved") end
        if on_done then on_done(ok) end
      end)
    else
      core.error("LeetCode login was not captured.")
      core.redraw = true
      if on_done then on_done(false) end
    end
  end)
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
  local argv = { python, "-u", script, "--resume", "--out", out_dir }
  -- The cookie goes over stdin so it never sits in a file or an argument list.
  if cookie and cookie ~= "" then argv[#argv + 1] = "--cookie-stdin" end
  if state.output then
    state.output:clear()
    state.output.follow = true
  end
  local session = require "plugins.prep.session"
  session.show("Output")
  output_line("Syncing questions...")
  note_progress("Syncing questions...")
  local proc, err = process.start(argv, {
    cwd = dirname(script),
    env = util.runtime_env({ python }, {
      LEETCODE_USER_AGENT = util.user_agent(),
      PYTHONUNBUFFERED = "1",
    }),
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then
    state.sync_status = nil
    core.redraw = true
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
      on_out = function(text)
        if state.output then state.output:add(text, "out") end
        note_progress(text)
      end,
      on_err = function(text)
        if state.output then state.output:add(text, "err") end
        note_progress(text)
      end,
    })
    local code = proc:returncode() or 0
    local summary = state.sync_status
    state.sync_status = nil
    core.redraw = true
    if not (code == 0 and summary and summary:find("^Done%.", 1)) then
      summary = "Sync finished (" .. tostring(code) .. ")."
      output_line(summary)
    end
    core.status_view:show_message("i", require("core.style").text, summary or "Sync finished.")
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
      leetcode.capture(function(ok)
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
