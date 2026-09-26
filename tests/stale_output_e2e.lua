-- Redefine a function and rerun its unchanged caller through <C-CR>.
-- Requires a built backend and Python with ipykernel. Optional overrides:
-- JUPYNVIM_TEST_CORE=/path/to/jupynvim-core JUPYNVIM_TEST_PYTHON=/path/to/python
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local J = require("jupynvim")
local NB = require("jupynvim.notebook")
local CM = require("jupynvim.notebook.cellmode")
local tmp = vim.fn.tempname() .. ".ipynb"
local buf, client, sid
local failures = {}
local function chk(name, ok, detail)
  io.write((ok and "  ok " or "FAIL ") .. name .. (not ok and detail and (" -- " .. detail) or "") .. "\n")
  if not ok then failures[#failures + 1] = name end
end

local ok, err = xpcall(function()
  J.setup({ core_path = vim.env.JUPYNVIM_TEST_CORE, auto_install = false, log_level = "warn" })
  local function code(id, source)
    return { id = id, cell_type = "code", source = source, metadata = vim.empty_dict(),
      execution_count = vim.NIL, outputs = {} }
  end
  local file = assert(io.open(tmp, "w"))
  file:write(vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    code("definition", "def f():\n    return 'old'"), code("caller", "print(f())"),
  } }))
  file:close()
  client = J._ensure_client()
  local open_err, result = client:call_sync("open", { path = tmp })
  assert(not open_err, tostring(open_err))
  sid = result.session_id
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local nb = NB.create(buf, tmp, sid, result.snapshot)
  J._populate_buffer(nb)
  require("jupynvim.notebook.keymaps").attach(buf, J)

  local python = vim.env.JUPYNVIM_TEST_PYTHON or vim.fn.exepath("python3")
  local start_err = client:call_sync("start_kernel", { session_id = sid, python_path = python }, 20000)
  assert(not start_err, tostring(start_err))

  local function run(idx)
    local cell = nb.cells[idx]
    local before = tonumber(cell.execution_count) or 0
    vim.api.nvim_win_set_cursor(0, { CM.ranges(buf)[idx].start + 1, 0 })
    vim.cmd("normal " .. vim.api.nvim_replace_termcodes("<C-CR>", true, false, true))
    assert(vim.wait(10000, function()
      local state = nb.cell_state[cell.id]
      return (tonumber(cell.execution_count) or 0) > before and state and state.exec_state == "idle"
    end, 5), "cell did not finish: " .. cell.id)
    -- Let the real debounced output writer run, then inspect buffer text.
    vim.wait(250)
  end

  for _, value in ipairs({ "old", "new", "two", "six" }) do
    local r = CM.ranges(buf)[1]
    vim.api.nvim_buf_set_lines(buf, r.start, r.stop, false, { "def f():", "    return '" .. value .. "'" })
    run(1)
    run(2)
    local caller = nb.cells[2]
    local actual = caller.outputs[1] and caller.outputs[1].text
    chk(value .. ": kernel returned the new function result", actual == value .. "\n", tostring(actual))
    chk(value .. ": caller source stayed unchanged", caller.source == "print(f())", caller.source)
    local out = CM.ranges(buf)[2]
    local visible = out.out_sep and table.concat(vim.api.nvim_buf_get_lines(buf, out.out_sep + 1, out.out_stop, false), "\n")
    chk(value .. ": buffer displays that result", visible == "  " .. value, tostring(visible))
  end

  J._save(nb)
  local saved = vim.json.decode(table.concat(vim.fn.readfile(tmp), "\n"))
  chk("save persists the current result", saved.cells[2].outputs[1].text == "six\n")
end, debug.traceback)
if not ok then chk("end-to-end test completed", false, err) end

if client and sid then client:call_sync("close", { session_id = sid }, 5000) end
if buf then NB.remove(buf); pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
if client then client:stop() end
os.remove(tmp)
if #failures > 0 then
  io.write(#failures .. " STALE-OUTPUT E2E CHECKS FAILED\n")
  vim.cmd("cquit 1")
else
  io.write("ALL STALE-OUTPUT E2E CHECKS PASSED\n")
  vim.cmd("qa!")
end
