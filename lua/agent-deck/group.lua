-- group.lua — project identity resolution
-- Priority (highest → lowest):
--   1. mywm.current.name         explicit workspace
--   2. project_nvim root         most reliable for code projects
--   3. git root basename         matches title.lua convention
--   4. vim.fs.basename(cwd)      last resort
local M = {}

--- Convert a display name to a slug: "My Project" → "my-project"
function M.slugify(name)
  return (name:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""))
end

--- Resolve the current project name (slugified).
function M.current_project()
  -- 1. mywm workspace name
  local ok_mywm, mywm = pcall(require, "mywm")
  if ok_mywm and mywm.current and mywm.current.name then
    return M.slugify(mywm.current.name)
  end

  -- 2. project_nvim root (equally important for code projects)
  local ok_proj, proj = pcall(require, "project_nvim.project")
  if ok_proj and proj then
    local ok_root, root = pcall(function()
      -- get_project_root() may return (root, method)
      local r = proj.get_project_root()
      return r
    end)
    if ok_root and root and root ~= "" then
      return M.slugify(vim.fs.basename(root))
    end
  end

  -- 3. git root basename
  local git_root = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and git_root[1] and git_root[1] ~= "" then
    return M.slugify(vim.fs.basename(git_root[1]))
  end

  -- 4. cwd basename
  return M.slugify(vim.fs.basename(vim.fn.getcwd()))
end

return M
