-- mod-version:4
---Shared handles so modules can talk without requiring each other in a cycle.
local state = {
  session = nil,
  sessions = {},
  sidebar = nil,
  panel = nil,
  output = nil,
  runbar = nil,
  views = {},
  leetcode_user = nil,
}

return state
