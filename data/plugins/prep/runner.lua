-- mod-version:4
local core = require "core"
local config = require "core.config"
local json = require "plugins.prep.json"
local state = require "plugins.prep.state"
local util = require "plugins.prep.util"

local runner = {}
local active

local function output()
  return state.output
end

local function runtime(name)
  return util.join(util.plugin_dir(), "runtime" .. PATHSEP .. name)
end

function runner.language_label(language)
  if language == "javascript" then return "Node" end
  return "Python"
end

function runner.toggle_language()
  local session = require "plugins.prep.session"
  session.toggle_language()
end

local resolved_bins = {}

---Find a binary the way the user's terminal would. A GUI app launched from
---Finder has a bare PATH, and nvm or pyenv are usually set up in .zshrc, which
---only an interactive shell reads. Must run inside a thread.
local function resolve_bin(configured)
  if not configured or configured == "" then return configured end
  if configured:find("/", 1, true) then return configured end
  if resolved_bins[configured] then return resolved_bins[configured] end
  local shell = os.getenv("SHELL") or "/bin/sh"
  local name = shell:match("([^/]+)$") or ""
  local flags = (name == "zsh" or name == "bash") and "-ilc" or "-lc"
  local found
  if PLATFORM ~= "Windows" then
    local proc = process.start({ shell, flags, "command -v " .. configured }, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
    })
    if proc then
      local lines = {}
      util.stream_process(proc, {
        timeout = 8,
        on_out = function(text)
          for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
        end,
      })
      -- An interactive shell may print banners first. The answer is the last absolute path.
      for i = #lines, 1, -1 do
        if lines[i]:sub(1, 1) == "/" then found = lines[i]:gsub("%s+$", ""); break end
      end
    end
  end
  found = found or configured
  resolved_bins[configured] = found
  return found
end

local function focused_code(session)
  local view = core.active_view
  local doc = view and view.doc
  if not doc or doc.read_only or not doc.abs_filename then return nil end
  local prefix = session.dir .. PATHSEP
  if doc.abs_filename:sub(1, #prefix) ~= prefix then return nil end
  if doc.abs_filename:match("%.py$") or doc.abs_filename:match("%.js$") then
    return doc
  end
end

local function command_for(path, python_bin, node_bin)
  if path:match("%.js$") then
    return { node_bin, runtime("run.js"), path }
  end
  return { python_bin, "-u", runtime("run.py"), path }
end

local function write_spec(session)
  local question = session.question
  if not question.meta then return nil end
  local spec = {
    name = question.meta.name,
    params = question.meta.params or {},
    ["return"] = question.meta["return"],
    examples = question.examples or "",
  }
  local path = util.join(session.dir, "examples.json")
  util.write_file(path, json.encode(spec))
  return path
end

function runner.stop()
  if active and active.proc then
    active.stopped = true
    pcall(function() active.proc:kill() end)
  end
end

function runner.run(examples)
  local session = state.session
  if not session then
    core.error("Open a question first.")
    return
  end
  local round = session.question.round
  if round ~= "coding" and round ~= "debug" then
    core.error("This round has nothing to run.")
    return
  end
  if session.running then
    core.error("A run is already in progress.")
    return
  end
  local doc = focused_code(session) or session.solution_doc
  if doc and doc:is_dirty() and not doc.read_only then
    doc:save()
  end
  local path = (doc and doc.abs_filename) or session.solution_path
  if not path or not system.get_file_info(path) then
    core.error("No solution file to run.")
    return
  end
  local spec_path
  if examples then
    if not session.question.meta or not session.question.examples or session.question.examples == "" then
      core.error("This question has no example harness.")
      return
    end
    spec_path = write_spec(session)
  end
  local env_extra = spec_path and { PREP_SPEC = spec_path } or nil
  if output() then
    output():clear()
    output().follow = true
    output():add(examples and "Running examples..." or "Running...", "meta")
  end
  local session_mod = require "plugins.prep.session"
  session_mod.show("Output")
  session.running = true
  core.redraw = true
  local timeout = config.plugins.prep.timeout or 10
  core.add_thread(function()
    local cfg = config.plugins.prep
    local python_bin = resolve_bin(cfg.python or "python3")
    local node_bin = resolve_bin(cfg.node or "node")
    local argv = command_for(path, python_bin, node_bin)
    local proc, err = process.start(argv, {
      cwd = session.dir,
      env = util.runtime_env({ python_bin, node_bin }, env_extra),
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
    })
    if not proc then
      session.running = false
      local hint = session.language == "javascript" and "node" or "python"
      core.error("Could not start the runner: %s. Set config.plugins.prep.%s to a full path.", tostring(err), hint)
      if output() then output():add(tostring(err), "err") end
      active = nil
      return
    end
    active = { proc = proc, stopped = false }
    local started = system.get_time()
    if output() then output():add("using " .. argv[1], "meta") end
    local timed_out = util.stream_process(proc, {
      timeout = timeout,
      on_out = function(text) if output() then output():add(text, "out") end end,
      on_err = function(text) if output() then output():add(text, "err") end end,
    })
    if output() then
      if timed_out then
        output():add("Stopped after " .. timeout .. "s.", "err")
      elseif active and active.stopped then
        output():add("Stopped.", "err")
      end
    end
    local code = proc:returncode()
    local elapsed = system.get_time() - started
    if output() then
      output():add(string.format("exit %s   %.2fs", tostring(code or "?"), elapsed), "meta")
    end
    session.running = false
    if state.session == session then
      session.last_output = output() and output():get_text() or ""
    end
    active = nil
    core.redraw = true
  end)
end

return runner
