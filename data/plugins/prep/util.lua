-- mod-version:4
local core = require "core"
local common = require "core.common"

local util = {}

function util.prep_dir()
  return USERDIR .. PATHSEP .. "prep"
end

function util.plugin_dir()
  return DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "prep"
end

---Interpreter shipped inside the app bundle. Absent in a source checkout,
---which keeps the system python3 and node.
function util.bundled_bin(kind)
  local file = kind == "node" and "node" or "python3"
  local path = DATADIR .. PATHSEP .. "runtimes" .. PATHSEP .. kind .. PATHSEP .. "bin" .. PATHSEP .. file
  local info = system.get_file_info(path)
  if info and info.type == "file" then return path end
end

---Environment for a solution or helper process. Bundled interpreters are put
---on PATH, and a bundled Python ignores the user's site-packages.
function util.runtime_env(bins, extra)
  local env = {}
  if extra then
    for key, value in pairs(extra) do env[key] = value end
  end
  local prefix = {}
  for _, bin in ipairs(bins or {}) do
    local dir = type(bin) == "string" and bin:match("^(.*)[/\\][^/\\]+$")
    if dir and dir:find(PATHSEP .. "runtimes" .. PATHSEP, 1, true) then
      prefix[#prefix + 1] = dir
    end
  end
  if #prefix == 0 and not extra then return nil end
  if #prefix > 0 then
    env.PATH = table.concat(prefix, ":") .. ":" .. (os.getenv("PATH") or "/usr/bin:/bin")
    env.PYTHONNOUSERSITE = "1"
    env.PYTHONDONTWRITEBYTECODE = "1"
  end
  return env
end

function util.sessions_dir()
  return util.prep_dir() .. PATHSEP .. "sessions"
end

function util.ensure_dir(path)
  if not path or path == "" then return false, "empty path" end
  if system.get_file_info(path) then return true end
  return common.mkdirp(path)
end

function util.join(dir, name)
  return dir .. PATHSEP .. name
end

function util.read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

function util.write_file(path, text)
  local dir = common.dirname(path)
  if dir then
    local ok, err = util.ensure_dir(dir)
    if not ok then return nil, err end
  end
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  file:write(text or "")
  file:close()
  return true
end

function util.today()
  return os.date("%Y-%m-%d")
end

---Sortable timestamp. A later clock time on the same day sorts after an earlier one.
function util.now()
  return os.date("%Y-%m-%d %H:%M:%S")
end

---Wait for a process without caring whether we run inside a coroutine.
---The raw process:wait() takes milliseconds, the wrapper takes seconds,
---so poll instead of choosing between them.
function util.wait(proc, seconds)
  local start = system.get_time()
  while proc:running() and system.get_time() - start < seconds do
    if coroutine.isyieldable() then
      coroutine.yield(0.01)
    else
      system.sleep(0.005)
    end
  end
  return not proc:running()
end

---Write a file readable only by the current user. The file is created under
---umask 077 before any secret is written, and the path is passed as an
---argument so the shell never parses it.
function util.write_private(path, text)
  local dir = common.dirname(path)
  if dir then
    local ok, err = util.ensure_dir(dir)
    if not ok then return nil, err end
  end
  if PLATFORM ~= "Windows" then
    local proc = process.start(
      { "/bin/sh", "-c", 'umask 077; : >> "$1"; chmod 600 "$1"', "sh", path },
      { stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD }
    )
    if proc then util.wait(proc, 5) end
  end
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  file:write(text or "")
  file:close()
  return true
end

local function curl_quote(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

---Text for `curl --config -`. Headers and the body travel over stdin, so
---neither a secret nor the request ever touches the argument list or a file.
function util.curl_config_text(headers, body)
  local lines = {}
  for _, header in ipairs(headers) do
    lines[#lines + 1] = "header = " .. curl_quote(header)
  end
  if body then
    lines[#lines + 1] = "data-binary = " .. curl_quote(body)
  end
  return table.concat(lines, "\n") .. "\n"
end

---Run curl with a config on stdin and return stdout, stderr. Call from a thread.
function util.curl(url, headers, body, max_time)
  local proc, err = process.start({
    "curl", "-sS", "--max-time", tostring(max_time or 60),
    "-X", "POST", url, "--config", "-",
  }, {
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then return nil, nil, "curl failed to start: " .. tostring(err) end
  proc.stdin:write(util.curl_config_text(headers, body))
  proc.stdin:close()
  -- stream:read("all") can wait forever for an EOF that never arrives as a
  -- result, so collect through the same bounded pump the runner uses.
  local out, errs = {}, {}
  util.stream_process(proc, {
    timeout = (max_time or 60) + 5,
    on_out = function(text) out[#out + 1] = text end,
    on_err = function(text) errs[#errs + 1] = text end,
  })
  return table.concat(out), table.concat(errs)
end

---Read a process to the end without starving the UI. Output is delivered in
---complete lines, a bounded amount per frame, and the thread yields every
---pass so a process that prints nonstop cannot freeze the editor.
---opts: on_out(text), on_err(text), timeout (seconds)
---Returns true when the process was killed for running too long.
function util.stream_process(proc, opts)
  local raw = proc.process
  local started = system.get_time()
  local pending = { [process.STREAM_STDOUT] = "", [process.STREAM_STDERR] = "" }
  local handlers = {
    [process.STREAM_STDOUT] = opts.on_out,
    [process.STREAM_STDERR] = opts.on_err,
  }
  local timed_out = false

  local function emit(fd, final)
    local text = pending[fd]
    if text == "" then return end
    local cut = final and #text or select(2, text:find(".*\n")) or 0
    if cut == 0 and #text > 65536 then cut = #text end
    if cut > 0 and handlers[fd] then
      handlers[fd](text:sub(1, cut))
      pending[fd] = text:sub(cut + 1)
    end
  end

  while true do
    local got = false
    for fd in pairs(pending) do
      local ok, chunk = pcall(raw.read, raw, fd, 32768)
      if ok and chunk and #chunk > 0 then
        pending[fd] = pending[fd] .. chunk
        emit(fd, false)
        got = true
      end
    end
    local running = proc:running()
    if not running and not got then break end
    if running and opts.timeout and not timed_out and system.get_time() - started > opts.timeout then
      timed_out = true
      pcall(function() proc:kill() end)
    end
    coroutine.yield(got and 0 or 0.03)
  end
  for fd in pairs(pending) do emit(fd, true) end
  return timed_out
end

util.default_ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

---The browser User-Agent. Cloudflare ties its clearance cookie to the browser
---that earned it, so this can be overridden with the one from the browser.
function util.user_agent()
  local config = require "core.config"
  local ua = config.plugins.prep and config.plugins.prep.user_agent
  if type(ua) == "string" and ua ~= "" then return ua end
  return util.default_ua
end

function util.add_days(date, days)
  local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
  if not y then return util.today() end
  return os.date("%Y-%m-%d", os.time({
    year = tonumber(y), month = tonumber(m), day = tonumber(d),
    hour = 12,
  }) + days * 86400)
end

---Collapse whitespace and cut to a byte length without splitting a UTF-8 character.
function util.clip(text, max)
  text = tostring(text or "")
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #text <= max then return text end
  local cut = max
  while cut > 1 and common.is_utf8_cont(text, cut) do
    cut = cut - 1
  end
  if cut <= 1 then return "" end
  return text:sub(1, cut - 1) .. "…"
end

function util.safe_name(text)
  local name = tostring(text or "question"):gsub("[^%w%-_]", "-")
  name = name:gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if name == "" then name = "question" end
  return name
end

function util.doc_text(doc)
  if not doc or not doc.lines or #doc.lines == 0 then return "" end
  return doc:get_text(1, 1, #doc.lines, math.huge)
end

function util.wrap(font, text, max_width)
  local lines = {}
  max_width = math.max(max_width or 0, font:get_width("M"))
  local function break_token(word)
    local chunk = ""
    for char in common.utf8_chars(word) do
      local trial = chunk .. char
      if chunk ~= "" and font:get_width(trial) > max_width then
        lines[#lines + 1] = chunk
        chunk = char
      else
        chunk = trial
      end
    end
    return chunk
  end
  for para in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      lines[#lines + 1] = ""
    else
      local line = ""
      for word in para:gmatch("%S+") do
        local trial = line == "" and word or (line .. " " .. word)
        if font:get_width(trial) <= max_width then
          line = trial
        else
          if line ~= "" then
            lines[#lines + 1] = line
          end
          if font:get_width(word) > max_width then
            line = break_token(word)
          else
            line = word
          end
        end
      end
      if line ~= "" then lines[#lines + 1] = line end
    end
  end
  return lines
end

function util.good()
  local style = require "core.style"
  return style.good or style.accent
end

function util.warn()
  local style = require "core.style"
  return style.warn or style.accent
end

function util.err()
  local style = require "core.style"
  return style.error or style.accent
end

function util.log(fmt, ...)
  core.log("[" .. "prep" .. "] " .. fmt, ...)
end

function util.prep_script(name)
  local config = require "core.config"
  local configured = name == "fetch_questions.py" and config.plugins.prep and config.plugins.prep.fetch_script
  local candidates = {
    configured,
    util.plugin_dir() .. PATHSEP .. name,
    DATADIR .. PATHSEP .. ".." .. PATHSEP .. "scripts" .. PATHSEP .. "prep" .. PATHSEP .. name,
  }
  for _, path in ipairs(candidates) do
    if type(path) == "string" and path ~= "" and system.get_file_info(path) then
      return path
    end
  end
  return candidates[2]
end

function util.fetch_script()
  return util.prep_script("fetch_questions.py")
end

return util
