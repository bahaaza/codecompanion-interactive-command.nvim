local Extension = {}

---@param opts? { add_to_agent?: boolean, close_delay_ms?: integer }
function Extension.setup(opts)
  opts = opts or {}
  local delay = opts.close_delay_ms
  if delay ~= nil then
    assert(type(delay) == "number" and delay >= 0 and delay % 1 == 0, "close_delay_ms must be a non-negative integer")
  end
  local tools = require("codecompanion.config").interactions.chat.tools
  tools.interactive_command = vim.tbl_deep_extend("keep", tools.interactive_command or {}, {
    path = "codecompanion._extensions.interactive_command.tool",
    description = "Run interactive or long-lived commands in a terminal",
    opts = {
      close_delay_ms = delay,
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
