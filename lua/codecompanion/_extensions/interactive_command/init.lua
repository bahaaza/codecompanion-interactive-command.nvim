local Extension = {}

---@param opts? { add_to_agent?: boolean }
function Extension.setup(opts)
  opts = opts or {}
  local tools = require("codecompanion.config").interactions.chat.tools
  tools.interactive_command = vim.tbl_deep_extend("keep", tools.interactive_command or {}, {
    path = "codecompanion._extensions.interactive_command.tool",
    description = "Run interactive or long-lived commands in a terminal",
    opts = {
      require_approval_before = function(tool)
        return tool.args.action == "start" or tool.args.action == "send"
      end,
      require_cmd_approval = true,
    },
  })

  local agent = tools.groups and tools.groups.agent
  if opts.add_to_agent ~= false and agent and not vim.tbl_contains(agent.tools, "interactive_command") then
    table.insert(agent.tools, "interactive_command")
  end
end

return Extension
