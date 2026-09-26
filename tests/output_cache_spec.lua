-- Fast executions can clear and replace outputs before the 150ms buffer
-- refresh. Equal-length results must not reuse text from the previous run.
-- This spec needs only Neovim; no backend or Python kernel is required.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local NB = require("jupynvim.notebook")
local fails = 0
local function chk(name, ok, detail)
  if ok then io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail and (" -- " .. detail) or "") .. "\n")
    fails = fails + 1
  end
end

local function fixture()
  local buf = vim.api.nvim_create_buf(false, true)
  local nb = NB.create(buf, "test.ipynb", "s", { cells = {
    { id = "c1", cell_type = "code", source = "f()", outputs = {} },
  } })
  return nb, nb.cells[1]
end

local function stream(text)
  return { kind = "stream", name = "stdout", text = text .. "\n" }
end

local cases = {
  { "stdout", stream("old"), stream("new"), "  new" },
  { "expression", { kind = "execute_result", execution_count = 1, data = { ["text/plain"] = "100" } },
    { kind = "execute_result", execution_count = 2, data = { ["text/plain"] = "200" } }, "  200" },
  { "display", { kind = "display_data", data = { ["text/plain"] = "old" } },
    { kind = "display_data", data = { ["text/plain"] = "new" } }, "  new" },
  { "error", { kind = "error", ename = "ValueError", evalue = "old", traceback = { "old traceback" } },
    { kind = "error", ename = "ValueError", evalue = "new", traceback = { "new traceback" } },
    "  ValueError: new\n  new traceback" },
}

for _, case in ipairs(cases) do
  local nb, cell = fixture()
  nb:apply_cell_event("c1", { kind = "execute_input", execution_count = 1 })
  nb:apply_cell_event("c1", case[2])
  local before = NB.output_lines(cell)
  chk(case[1] .. ": unchanged output reuses the cache", NB.output_lines(cell) == before)
  -- Do not render between execute_input and the new output: a quick run
  -- finishes before the debounced buffer write sees the cleared outputs.
  nb:apply_cell_event("c1", { kind = "execute_input", execution_count = 2 })
  nb:apply_cell_event("c1", case[3])
  local after = table.concat(NB.output_lines(cell), "\n")
  chk(case[1] .. ": rerun shows new equal-length output", after == case[4], after)
  local rendered = table.concat(nb:to_lines(), "\n")
  chk(case[1] .. ": notebook layout includes the new output", rendered:find(case[4], 1, true) ~= nil)
  NB.remove(nb.buf)
  vim.api.nvim_buf_delete(nb.buf, { force = true })
end

for _, wait in ipairs({ false, true }) do
  local nb, cell = fixture()
  nb:apply_cell_event("c1", stream("old"))
  NB.output_lines(cell)
  nb:apply_cell_event("c1", { kind = "clear_output", wait = wait })
  local ev = stream("new")
  -- The backend marks the first output after clear_output(wait=True).
  ev.clear_first = wait
  nb:apply_cell_event("c1", ev)
  chk("clear_output(wait=" .. tostring(wait) .. "): shows replacement text",
      table.concat(NB.output_lines(cell), "\n") == "  new")
  NB.remove(nb.buf)
  vim.api.nvim_buf_delete(nb.buf, { force = true })
end

do
  local nb, cell = fixture()
  nb:apply_cell_event("c1", { kind = "display_data", data = { ["text/plain"] = "old" },
    transient = { display_id = "d1" } })
  NB.output_lines(cell)
  nb:apply_cell_event("c1", { kind = "update_display_data", display_id = "d1",
    data = { ["text/plain"] = "new" }, metadata = {} })
  chk("display handle: in-place equal-length update still invalidates the cache",
      table.concat(NB.output_lines(cell), "\n") == "  new")
  NB.remove(nb.buf)
  vim.api.nvim_buf_delete(nb.buf, { force = true })
end

if fails > 0 then
  io.write(fails .. " OUTPUT-CACHE CHECKS FAILED\n")
  vim.cmd("cquit 1")
else
  io.write("ALL OUTPUT-CACHE CHECKS PASSED\n")
  vim.cmd("qa!")
end
