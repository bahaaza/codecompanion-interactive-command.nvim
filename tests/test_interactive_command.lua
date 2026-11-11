local h = require("tests.helpers")

local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        vim.opt.runtimepath:append(vim.env.CODECOMPANION_INTERACTIVE_PATH)
        h = require("tests.helpers")
        chat, tools = h.setup_chat_buffer()
        require("codecompanion").register_extension("interactive_command",
          require("codecompanion._extensions.interactive_command"))
        require("codecompanion.config").interactions.chat.tools.interactive_command.opts.require_approval_before = false
        tools:refresh({ adapter = chat.adapter })
        chat.tools:refresh({ adapter = chat.adapter })
        chat.tools:parse(chat, { content = "@{interactive_command}" })
        _G.after_tools = require("codecompanion.interactions.chat.agent_loop").after_tools
        require("codecompanion.interactions.chat.agent_loop").after_tools = function(running_tools)
          running_tools:reset()
        end
        _G.call_interactive_command = function(args)
          local previous_messages = #chat.messages
          tools:execute(chat, {
            { ["function"] = { name = "interactive_command", arguments = vim.json.encode(args) } },
          })
          vim.wait(5000, function()
            return #chat.messages > previous_messages
          end, 20)
          return chat.messages[#chat.messages].content
        end
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["interactive_command"] = MiniTest.new_set()

T["interactive_command"]["loads from setup and joins the agent group"] = function()
  child.lua([[
    h.setup_plugin(vim.tbl_deep_extend("force", vim.deepcopy(require("tests.config")), {
      extensions = { interactive_command = {} },
    }))
    local configured_chat = require("codecompanion.interactions.chat").new({
      buffer_context = { bufnr = 1, filetype = "lua" },
      adapter = "test_adapter",
    })
    configured_chat.tools:parse(configured_chat, { content = "@{agent}" })
    _G.tool_available = configured_chat.tool_registry.in_use.interactive_command ~= nil
    configured_chat:close()
  ]])

  h.eq(true, child.lua_get("_G.tool_available"))
end

T["interactive_command"]["starts without waiting and returns later output"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  local started = child.lua_get(
    [[_G.call_interactive_command({ action = "start", command = "printf first; sleep 0.5; printf second" })]]
  )
  local job_id = tonumber(started:match("Started command (%d+)"))
  h.eq(true, job_id ~= nil)
  h.eq(-1, child.lua_get(string.format("vim.fn.jobwait({ %d }, 0)[1]", job_id)))

  local first = child.lua_get(
    string.format([[_G.call_interactive_command({ action = "read", job_id = %d, wait_ms = 2000 })]], job_id)
  )
  h.expect_contains("first", first)

  local second = child.lua_get(
    string.format([[_G.call_interactive_command({ action = "read", job_id = %d, wait_ms = 2000 })]], job_id)
  )
  h.expect_contains("second", second)
  child.lua(string.format("vim.fn.jobwait({ %d }, 3000)", job_id))
  local completed =
    child.lua_get(string.format([[_G.call_interactive_command({ action = "read", job_id = %d })]], job_id))
  h.expect_contains("exited with code 0", completed)
end

T["interactive_command"]["sends terminal input and reports the response"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  local started = child.lua_get(
    [[_G.call_interactive_command({ action = "start", command = "read answer; printf 'received:%s\\n' \"$answer\"" })]]
  )
  local job_id = tonumber(started:match("Started command (%d+)"))
  h.eq(true, job_id ~= nil)

  local sent = child.lua_get(
    string.format([[_G.call_interactive_command({ action = "send", job_id = %d, input = "hello\n" })]], job_id)
  )
  h.expect_contains("Sent input", sent)
  local output = child.lua_get(
    string.format([[_G.call_interactive_command({ action = "read", job_id = %d, wait_ms = 2000 })]], job_id)
  )
  if not output:find("received:hello", 1, true) then
    output = child.lua_get(
      string.format([[_G.call_interactive_command({ action = "read", job_id = %d, wait_ms = 2000 })]], job_id)
    )
  end
  h.expect_contains("received:hello", output)
  local terminal_buffer = tonumber(started:match("terminal buffer (%d+)"))
  h.expect_contains(
    "received:hello",
    child.lua_get(string.format("table.concat(vim.api.nvim_buf_get_lines(%d, 0, -1, false), '\\n')", terminal_buffer))
  )
end

T["interactive_command"]["sends command output in the next agent request"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    local started = _G.call_interactive_command({ action = "start", command = "printf agent-feedback" })
    local job_id = tonumber(started:match("Started command (%d+)"))
    vim.wait(3000, function()
      return vim.fn.jobwait({ job_id }, 0)[1] ~= -1
    end, 20)
    require("codecompanion.interactions.chat.agent_loop").after_tools = _G.after_tools
    chat._submit_http = function(_, payload)
      _G.agent_request = payload
    end
    chat.status = "success"
    chat:done({ tools = {
      { id = "read_command", type = "function", ["function"] = {
        name = "interactive_command",
        arguments = vim.json.encode({ action = "read", job_id = job_id }),
      } },
    } })
    vim.wait(3000, function()
      return _G.agent_request ~= nil
    end, 20)
    _G.feedback = nil
    for _, message in ipairs(_G.agent_request.messages) do
      if message.role == "tool" and message.tools.call_id == "read_command" then
        _G.feedback = message.content
      end
    end
  ]])

  h.expect_contains("agent-feedback", child.lua_get("_G.feedback"))
  h.expect_contains("exited with code 0", child.lua_get("_G.feedback"))
end

T["interactive_command"]["stop terminates a running command"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    _G.marker = vim.fn.tempname()
    _G.started = _G.call_interactive_command({ action = "start", command = "sleep 1; touch " .. _G.marker })
    _G.job_id = tonumber(_G.started:match("Started command (%d+)"))
    _G.stopped = _G.call_interactive_command({ action = "stop", job_id = _G.job_id })
    vim.wait(1500)
  ]])

  h.expect_contains("Stopping command", child.lua_get("_G.stopped"))
  h.eq(0, child.lua_get("vim.fn.filereadable(_G.marker)"))
end

T["interactive_command"]["chat stop terminates a background command"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    _G.marker = vim.fn.tempname()
    _G.started = _G.call_interactive_command({ action = "start", command = "sleep 1; touch " .. _G.marker })
    chat:stop()
    vim.wait(1500)
  ]])

  h.expect_contains("Started command", child.lua_get("_G.started"))
  h.eq(0, child.lua_get("vim.fn.filereadable(_G.marker)"))
end

T["interactive_command"]["chat close terminates a background command"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    _G.marker = vim.fn.tempname()
    _G.started = _G.call_interactive_command({ action = "start", command = "sleep 1; touch " .. _G.marker })
    chat:close()
    vim.wait(1500)
  ]])

  h.expect_contains("Started command", child.lua_get("_G.started"))
  h.eq(0, child.lua_get("vim.fn.filereadable(_G.marker)"))
end

T["interactive_command"]["a cancelled read preserves later output"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    local started = _G.call_interactive_command({ action = "start", command = "sleep 0.3; printf later" })
    _G.job_id = tonumber(started:match("Started command (%d+)"))
    tools:execute(chat, {
      { ["function"] = {
        name = "interactive_command",
        arguments = vim.json.encode({ action = "read", job_id = _G.job_id, wait_ms = 2000 }),
      } },
    })
    chat.tool_orchestrator:cancel()
    vim.wait(700)
    _G.output = _G.call_interactive_command({ action = "read", job_id = _G.job_id })
  ]])

  h.expect_contains("later", child.lua_get("_G.output"))
end

T["interactive_command"]["truncates unread output at a complete character"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    local started = _G.call_interactive_command({
      action = "start",
      command = "printf '%s' '" .. string.rep("é", 8193) .. "a'",
    })
    local job_id = tonumber(started:match("Started command (%d+)"))
    vim.wait(3000, function()
      return vim.fn.jobwait({ job_id }, 0)[1] ~= -1
    end, 20)
    _G.output = _G.call_interactive_command({ action = "read", job_id = job_id })
    _G.retained = _G.output:match("````\n(.-)\n````")
  ]])

  h.expect_contains("Earlier unread output was truncated", child.lua_get("_G.output"))
  h.eq(true, child.lua_get([[_G.retained == string.rep("é", 8191) .. "a"]]))
end

T["interactive_command"]["waits for the rest of a character before returning output"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    local started = _G.call_interactive_command({
      action = "start",
      command = "printf '\\303'; sleep 0.5; printf '\\251'",
    })
    local job_id = tonumber(started:match("Started command (%d+)"))
    vim.wait(100)
    _G.first_output = _G.call_interactive_command({ action = "read", job_id = job_id })
    _G.complete_output = _G.call_interactive_command({ action = "read", job_id = job_id, wait_ms = 2000 })
  ]])

  h.expect_contains("No new output", child.lua_get("_G.first_output"))
  h.expect_contains("é", child.lua_get("_G.complete_output"))
end

T["interactive_command"]["approves execution and input and releases a running command"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("This test uses POSIX shell commands")
  end

  child.lua([[
    local config = require("codecompanion.config")
    config.interactions.chat.tools.interactive_command.opts.require_approval_before = function(tool)
      return tool.args.action == "start" or tool.args.action == "send"
    end
    tools:refresh({ adapter = chat.adapter })
    _G.approval_count = 0
    require("codecompanion.interactions.chat.helpers.approval_prompt").request = function(_, opts)
      _G.approval_count = _G.approval_count + 1
      for _, choice in ipairs(opts.choices) do
        if choice.keymap == "g2" then
          return choice.callback()
        end
      end
    end
    local started = _G.call_interactive_command({ action = "start", command = "read answer; sleep 30" })
    _G.job_id = tonumber(started:match("Started command (%d+)"))
    _G.call_interactive_command({ action = "send", job_id = _G.job_id, input = "hello\n" })
    _G.call_interactive_command({ action = "read", job_id = _G.job_id })
    _G.released = _G.call_interactive_command({ action = "release", job_id = _G.job_id })
    vim.wait(3000, function()
      return vim.fn.jobwait({ _G.job_id }, 0)[1] ~= -1
    end, 20)
  ]])

  h.eq(2, child.lua_get("_G.approval_count"))
  h.expect_contains("Released command", child.lua_get("_G.released"))
  h.eq(false, child.lua_get("vim.fn.jobwait({ _G.job_id }, 0)[1] == -1"))
end

return T
