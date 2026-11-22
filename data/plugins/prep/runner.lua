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
  if language == "java" then return "Java" end
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
  if doc.abs_filename:match("%.py$") or doc.abs_filename:match("%.js$") or doc.abs_filename:match("%.java$") then
    return doc
  end
end

local function is_abs(path)
  return type(path) == "string" and (path:find("/", 1, true) or path:find("\\", 1, true))
end

---javac lives next to java in a JDK. Prefer that sibling so the compiler and
---the runtime are the same installation.
local function javac_beside(java_bin, configured)
  if is_abs(configured) then return configured end
  if is_abs(java_bin) then
    local sibling = java_bin:gsub("java%.exe$", "javac.exe")
    if sibling == java_bin then sibling = java_bin:gsub("java$", "javac") end
    if sibling ~= java_bin and system.get_file_info(sibling) then return sibling end
  end
  return resolve_bin(configured or "javac")
end

local function remove_tree(path)
  local info = system.get_file_info(path)
  if not info then return end
  if info.type == "dir" then
    for _, name in ipairs(system.list_dir(path) or {}) do
      remove_tree(path .. PATHSEP .. name)
    end
    system.rmdir(path)
  else
    os.remove(path)
  end
end

local function java_sources(dir, path)
  local sources = {
    runtime("java" .. PATHSEP .. "ListNode.java"),
    runtime("java" .. PATHSEP .. "TreeNode.java"),
    runtime("java" .. PATHSEP .. "PrepRun.java"),
  }
  local seen = {}
  local function add(file)
    if type(file) == "string" and file ~= "" and not seen[file] then
      seen[file] = true
      sources[#sources + 1] = file
    end
  end
  add(path)
  for _, name in ipairs(system.list_dir(dir) or {}) do
    if name:match("%.java$") then add(util.join(dir, name)) end
  end
  return sources
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
    local started
    local deadline
    local function begin_clock()
      if started then return end
      started = system.get_time()
      deadline = started + timeout
    end
    local function remaining()
      begin_clock()
      local left = deadline - system.get_time()
      if left < 0.05 then return 0 end
      return left
    end
    local function remember()
      if state.session == session and output() then
        session.last_output = output():get_text()
      end
    end
    local function finish(code, timed_out, stopped)
      if output() then
        if timed_out then
          output():add("Stopped after " .. timeout .. "s.", "err")
        elseif stopped then
          output():add("Stopped.", "err")
        end
        local elapsed = started and (system.get_time() - started) or 0
        output():add(string.format("exit %s   %.2fs", tostring(code or "?"), elapsed), "meta")
      end
      session.running = false
      remember()
      active = nil
      core.redraw = true
    end
    local function fail_start(err, hint)
      session.running = false
      core.error("Could not start the runner: %s. Set config.plugins.prep.%s to a full path.", tostring(err), hint)
      if output() then output():add(tostring(err), "err") end
      remember()
      active = nil
      core.redraw = true
    end
    local function launch(argv, env, limit)
      begin_clock()
      local proc, err = process.start(argv, {
        cwd = session.dir,
        env = env,
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_PIPE,
      })
      if not proc then return nil, err end
      active = { proc = proc, stopped = false }
      if output() then output():add("using " .. argv[1], "meta") end
      local timed_out = util.stream_process(proc, {
        timeout = limit,
        on_out = function(text) if output() then output():add(text, "out") end end,
        on_err = function(text) if output() then output():add(text, "err") end end,
      })
      local stopped = active and active.stopped
      local code = proc:returncode()
      if code == nil then
        pcall(function() proc:wait(2000) end)
        code = proc:returncode()
      end
      return proc, nil, timed_out, stopped, code
    end

    if path:match("%.java$") then
      local java_bin = resolve_bin(cfg.java or "java")
      local javac_bin = javac_beside(java_bin, cfg.javac or "javac")
      local env = util.runtime_env({ java_bin, javac_bin }, env_extra)
      local classes = util.join(session.dir, "classes")
      remove_tree(classes)
      util.ensure_dir(classes)
      local argv = { javac_bin, "-encoding", "UTF-8", "-d", classes }
      for _, src in ipairs(java_sources(session.dir, path)) do
        argv[#argv + 1] = src
      end
      local proc, err, timed_out, stopped, code = launch(argv, env, remaining())
      if not proc then
        fail_start(err, "javac")
        return
      end
      if timed_out or stopped or code ~= 0 then
        finish(code, timed_out, stopped)
        return
      end
      local limit = remaining()
      if limit <= 0 then
        finish(code, true, false)
        return
      end
      proc, err, timed_out, stopped, code = launch(
        { java_bin, "-ea", "-cp", classes, "PrepRun" },
        env,
        limit
      )
      if not proc then
        fail_start(err, "java")
        return
      end
      finish(code, timed_out, stopped)
      return
    end

    local python_bin = resolve_bin(cfg.python or "python3")
    local node_bin = resolve_bin(cfg.node or "node")
    local argv = command_for(path, python_bin, node_bin)
    local proc, err, timed_out, stopped, code = launch(
      argv,
      util.runtime_env({ python_bin, node_bin }, env_extra),
      timeout
    )
    if not proc then
      local hint = session.language == "javascript" and "node" or "python"
      fail_start(err, hint)
      return
    end
    finish(code, timed_out, stopped)
  end)
end

return runner
