local approvals = require("codecompanion.interactions.chat.tools.approvals")
local log = require("codecompanion.utils.log")
local markdown = require("codecompanion.utils.markdown")

local fmt = string.format

local MAX_OUTPUT_BYTES = 1048576
local MAX_READ_BYTES = 16384
local jobs_by_chat = {}

---@param opts { output: string, offset: number }
---@return number
local function find_character_start(opts)
  local offset = opts.offset
  while (opts.output:byte(offset) or 0) >= 128 and (opts.output:byte(offset) or 0) < 192 do
    offset = offset + 1
  end
  return offset
end

---@param output string
---@return number
local function find_complete_end(output)
  local offset = #output
  while offset > 0 and output:byte(offset) >= 128 and output:byte(offset) < 192 do
    offset = offset - 1
  end
  local byte = output:byte(offset) or 0
  local length = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
  return #output - offset + 1 < length and offset - 1 or #output
end

---@param opts { job: table, output: string }
local function append_output(opts)
  local job = opts.job
  local output = job.pending_output .. opts.output
  local complete_end = find_complete_end(output)
  job.pending_output = output:sub(complete_end + 1)
  job.output = job.output .. output:sub(1, complete_end)
  if #job.output > MAX_OUTPUT_BYTES then
    local discarded = find_character_start({ output = job.output, offset = #job.output - MAX_OUTPUT_BYTES + 1 }) - 1
    job.output = job.output:sub(discarded + 1)
    job.output_start = job.output_start + discarded
  end
end

---@param opts { output: string }
---@return string
local function clean_output(opts)
  local output = opts.output
    :gsub("\27%][^\7]*\7", "")
    :gsub("\27%][^\27]*\27\\", "")
    :gsub("\27%[[0-?]*[ -/]*[@-~]", "")
    :gsub("\r\n", "\n")
    :gsub("\r", "\n")
  return output
end

---@param opts { job: table }
---@return string
local function read_output(opts)
  local job = opts.job
  local output_end = job.output_start + #job.output
  local read_from = math.max(job.read_offset, job.output_start, output_end - MAX_READ_BYTES)
  read_from = job.output_start
    + find_character_start({ output = job.output, offset = read_from - job.output_start + 1 })
    - 1
  local truncated = read_from > job.read_offset
  local output = clean_output({ output = job.output:sub(read_from - job.output_start + 1) })
  job.read_offset = output_end

  local status = job.exit_code and fmt("exited with code %d", job.exit_code) or "running"
  if job.stopping and not job.exit_code then
    status = "stopping"
  end
  local message = fmt("Command %d is %s.", job.id, status)
  if truncated then
    message = message .. " Earlier unread output was truncated."
  end
  if output ~= "" then
    message = message .. "\n" .. markdown.form_codeblock(output)
  else
    message = message .. " No new output."
  end
  return message
end

---@param opts { bufnr: number, remove: boolean }
local function stop_chat_jobs(opts)
  local jobs = jobs_by_chat[opts.bufnr]
  if not jobs then
    return
  end
  for _, job in pairs(jobs) do
    if not job.exit_code then
      job.stopping = true
      vim.fn.jobstop(job.id)
    end
  end
  if opts.remove then
    jobs_by_chat[opts.bufnr] = nil
  end
end

---@param chat CodeCompanion.Chat
local function register_chat(chat)
  if jobs_by_chat[chat.bufnr] then
    return
  end
  jobs_by_chat[chat.bufnr] = {}
  chat:add_callback("on_cancelled", function()
    stop_chat_jobs({ bufnr = chat.bufnr, remove = false })
  end)
  chat:add_callback("on_closed", function()
    stop_chat_jobs({ bufnr = chat.bufnr, remove = true })
  end)
end

---@param opts { chat: CodeCompanion.Chat, command: string }
---@return table|nil
local function start_command(opts)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "hide"
  local job = { buffer = buffer, output = "", pending_output = "", output_start = 1, read_offset = 1 }
  local ok, id = pcall(vim.api.nvim_buf_call, buffer, function()
    return vim.fn.jobstart(opts.command, {
      term = true,
      cwd = vim.fn.getcwd(),
      on_stdout = function(_, lines)
        append_output({ job = job, output = table.concat(lines, "\n") })
      end,
      on_exit = function(_, exit_code)
        job.exit_code = exit_code
      end,
    })
  end)
  if not ok or id <= 0 then
    log:error("Could not start interactive command: %s", tostring(id))
    vim.api.nvim_buf_delete(buffer, { force = true })
    return nil
  end

  job.id = id
  local opened, window = pcall(vim.api.nvim_open_win, buffer, false, { split = "below", height = 10 })
  if not opened then
    log:error("Could not open interactive command terminal: %s", tostring(window))
    vim.fn.jobstop(id)
    vim.api.nvim_buf_delete(buffer, { force = true })
    return nil
  end

  register_chat(opts.chat)
  jobs_by_chat[opts.chat.bufnr][id] = job
  return job
end

---@param opts { chat: CodeCompanion.Chat, job: table, wait_ms?: number, output_cb: fun(response: table) }
local function wait_for_output(opts)
  local orchestrator = opts.chat.tool_orchestrator
  local deadline = vim.uv.now() + math.min(math.max(opts.wait_ms or 0, 0), 30000)
  local function check()
    if orchestrator and orchestrator.cancelled then
      return
    end
    if
      opts.job.read_offset < opts.job.output_start + #opts.job.output
      or opts.job.exit_code
      or vim.uv.now() >= deadline
    then
      return opts.output_cb({ status = "success", data = read_output({ job = opts.job }) })
    end
    vim.defer_fn(check, 100)
  end
  check()
end

---@param opts { job: table, input?: string }
---@return table
local function send_input(opts)
  local job = opts.job
  if job.exit_code then
    return { status = "error", data = fmt("Command %d has exited", job.id) }
  end
  if type(opts.input) ~= "string" then
    return { status = "error", data = "Input must be a string" }
  end
  local ok, error_message = pcall(vim.fn.chansend, job.id, opts.input)
  if not ok then
    log:error("Could not send interactive command input: %s", error_message)
    return { status = "error", data = "Could not send input to the command" }
  end
  return { status = "success", data = fmt("Sent input to command %d.", job.id) }
end

---@param opts { chat: CodeCompanion.Chat, args: table, output_cb: fun(response: table) }
---@return table|nil
local function execute_command(opts)
  local args = opts.args
  if args.action == "start" then
    if type(args.command) ~= "string" or vim.trim(args.command) == "" then
      return { status = "error", data = "A command is required to start a process" }
    end
    local job = start_command({ chat = opts.chat, command = args.command })
    if not job then
      return { status = "error", data = "Could not start the command" }
    end
    return {
      status = "success",
      data = fmt("Started command %d in terminal buffer %d. Use read to get its output.", job.id, job.buffer),
    }
  end

  local job = jobs_by_chat[opts.chat.bufnr] and jobs_by_chat[opts.chat.bufnr][args.job_id]
  if not job then
    return { status = "error", data = "Unknown command ID for this chat" }
  end
  if args.action == "read" then
    wait_for_output({ chat = opts.chat, job = job, wait_ms = args.wait_ms, output_cb = opts.output_cb })
    return
  end
  if args.action == "send" then
    return send_input({ job = job, input = args.input })
  end
  if args.action == "stop" then
    if not job.exit_code then
      job.stopping = true
      vim.fn.jobstop(job.id)
    end
    return { status = "success", data = fmt("Stopping command %d. Use read to get its final output.", job.id) }
  end
  if args.action == "release" then
    if not job.exit_code then
      vim.fn.jobstop(job.id)
    end
    jobs_by_chat[opts.chat.bufnr][job.id] = nil
    return { status = "success", data = fmt("Released command %d.", job.id) }
  end
  return { status = "error", data = "Action must be start, read, send, stop, or release" }
end

---@class CodeCompanion.Tool.InteractiveCommand: CodeCompanion.Tools.Tool
return {
  name = "interactive_command",
  kind = "execute",
  cmds = {
    ---@param self CodeCompanion.Tools
    ---@param args table
    ---@param opts { output_cb: fun(response: table) }
    function(self, args, opts)
      return execute_command({ chat = self.chat, args = args, output_cb = opts.output_cb })
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "interactive_command",
      description = "Run a long-lived command in a visible terminal without waiting for it to exit. Start returns a command ID immediately. Read returns new output and exit status, optionally waiting up to 30 seconds. Send writes input to the terminal; include a newline when pressing Enter. Stop terminates the command; release stops it and removes its saved output. Use this instead of run_command for interactive or long-running processes.",
      parameters = {
        type = "object",
        properties = {
          action = { type = "string", enum = { "start", "read", "send", "stop", "release" } },
          command = { type = "string", description = "Shell command for start" },
          job_id = { type = "integer", description = "Command ID returned by start for read, send, stop, or release" },
          input = { type = "string", description = "Text to send to the terminal for send" },
          wait_ms = { type = "integer", description = "Maximum wait in milliseconds for read, up to 30000" },
        },
        required = { "action" },
        additionalProperties = false,
      },
    },
  },
  output = {
    ---@param self CodeCompanion.Tool.InteractiveCommand
    ---@return string
    cmd_string = function(self)
      local args = self.args
      if args.action == "start" then
        return args.command or "start command"
      end
      if args.action == "send" then
        return fmt("send %q to command %s", args.input or "", tostring(args.job_id))
      end
      return fmt("%s command %s", args.action or "interactive", tostring(args.job_id))
    end,
    ---@param self CodeCompanion.Tool.InteractiveCommand
    ---@param output string[]
    ---@param meta { tools: CodeCompanion.Tools }
    success = function(self, output, meta)
      meta.tools.chat:add_tool_output(self, { content = output[#output] })
    end,
    ---@param self CodeCompanion.Tool.InteractiveCommand
    ---@param errors table
    ---@param meta { tools: CodeCompanion.Tools }
    error = function(self, errors, meta)
      meta.tools.chat:add_tool_output(
        self,
        { content = table.concat(errors or { "Interactive command failed" }, "\n") }
      )
    end,
  },
  gates = {
    ---@param self CodeCompanion.Tool.InteractiveCommand
    ---@return boolean
    is_safe = function(self)
      return self.args.action == "start" and approvals.is_safe_command(self.args.command)
    end,
    ---@param self CodeCompanion.Tool.InteractiveCommand
    ---@return string
    judge_context = function(self)
      return self.output.cmd_string(self)
    end,
  },
}
