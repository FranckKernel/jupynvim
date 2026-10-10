-- How a cell shows its outputs, cut or expanded, #37.
--
-- <leader>no shows all of an output the cap cut, and cuts it again. On a plot
-- or a short print it changed nothing and still said "output expanded", which
-- read as broken. Expanding is a view of the cell. The .ipynb never sees it,
-- it leaves 'modified' as it was, and a save keeps it, because the undo file
-- read back on the next open has to match the buffer, output rows included.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path
vim.g.mapleader = " "

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/undo", "p")
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()
-- undo files and the notes saved with them land here, not in the real state
vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.o.undodir = tmp .. "/undo//"

local J      = require("jupynvim")
local NB     = require("jupynvim.notebook")
local CM     = require("jupynvim.notebook.cellmode")
local Image  = require("jupynvim.notebook.image")
local Render = require("jupynvim.notebook.render")
local K      = require("jupynvim.notebook.keymaps")
J.setup({ log_level = "warn", image_renderer = "placeholder" })

local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
local function said() return notes[#notes] end

local png = require("png_fixture")
local PLOT = vim.base64.encode(png(120, 90, 1))

local function printed(n, fmt)
  local t = {}
  for i = 1, n do t[i] = (fmt or "long line %d"):format(i) .. "\n" end
  return table.concat(t)
end

local function stream(text) return { output_type = "stream", name = "stdout", text = text } end
local function code(id, outputs)
  return { cell_type = "code", id = id, metadata = vim.empty_dict(), source = "pass  # " .. id,
           execution_count = #outputs > 0 and 1 or vim.NIL, outputs = outputs }
end

-- The notebook from the report, with its plot, a short print, a long one,
-- and a cell and a markdown cell with no output at all.
local function write_nb(p, long_n)
  local f = io.open(p, "w")
  f:write(vim.json.encode({
    cells = {
      { cell_type = "markdown", id = "how", metadata = vim.empty_dict(), source = "# notes" },
      code("plot", { { output_type = "display_data", metadata = vim.empty_dict(),
                       data = { ["image/png"] = PLOT, ["text/plain"] = "<Figure size 640x480 with 1 Axes>" } } }),
      code("short", { stream(printed(5, "short line %d")) }),
      code("long", { stream(printed(long_n or 1000)) }),
      code("empty", {}),
    },
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
    nbformat = 4, nbformat_minor = 5,
  }))
  f:close()
end

local function open(p)
  local buf = J.open(p)
  vim.wait(3000, function() return NB.get(buf) ~= nil end, 20)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function idx(buf, id)
  for i, c in ipairs(NB.get(buf).cells) do if c.id == id then return i end end
end
local function cell(buf, id) return NB.get(buf).cells[idx(buf, id)] end
local function range(buf, id) return CM.ranges(buf)[idx(buf, id)] end
-- the output rows under a cell as the buffer holds them, nil with none
local function region(buf, id)
  local r = range(buf, id)
  if not r.out_sep then return nil end
  return vim.api.nvim_buf_get_lines(buf, r.out_sep + 1, r.out_stop, false)
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end

local function on(buf, id) vim.api.nvim_win_set_cursor(0, { range(buf, id).start + 1, 0 }) end
local function expand(buf, id) on(buf, id); J.toggle_output_expand(buf); return said() end

-- Run what TextChanged runs after a keymap, which a headless run never
-- reaches on its own. That is where the buffer gets compared with the file.
local function changed(buf) vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf }) end

local function event(buf, id, ev)
  J._handle_cell_event({ session_id = NB.get(buf).session_id, cell_id = id, event = ev })
end
local function synced() vim.wait(600) end

-- the text render puts after the end of a 0-based row
local function hint(buf, row)
  Render.refresh_sync(NB.get(buf), vim.fn.bufwinid(buf))
  local marks = vim.api.nvim_buf_get_extmarks(buf, NB.get(buf).border_ns, { row, 0 }, { row, -1 },
                                              { details = true })
  for _, m in ipairs(marks) do
    if m[4].virt_text and m[4].virt_text_pos == "eol" then return m[4].virt_text[1][1] end
  end
  return nil
end

-- ── <leader>no on a cut output and on outputs with nothing cut ──────────
do
  local p = tmp .. "/views.ipynb"
  write_nb(p)
  local buf = open(p)
  local before = text(buf)

  for _, id in ipairs({ "plot", "short", "empty", "how" }) do
    local msg = expand(buf, id)
    chk("<leader>no on " .. id .. " says there is nothing to expand",
        msg == "jupynvim: nothing to expand", tostring(msg))
    chk("and changes nothing on " .. id, text(buf) == before and not cell(buf, id)._output_expanded)
  end

  local rows = region(buf, "long")
  chk("a 1000-line print is cut to the cap", #rows == 500, #rows .. " rows")
  chk("the marker says how many lines it hides, of how many",
      rows[126] == "  ⋯ 501 lines hidden (1000 total)", rows[126])
  chk("it hides exactly those lines",
      rows[125] == "  long line 125" and rows[127] == "  long line 627" and rows[500] == "  long line 1000",
      ("%s / %s / %s"):format(rows[125], rows[127], rows[500]))
  chk("the key to press follows the marker, outside the text",
      hint(buf, range(buf, "long").out_sep + 126) == " <leader>no to expand",
      tostring(hint(buf, range(buf, "long").out_sep + 126)))

  chk("<leader>no expands it", expand(buf, "long") == "jupynvim: output expanded", said())
  rows = region(buf, "long")
  chk("all 1000 lines show", #rows == 1000 and rows[1000] == "  long line 1000", #rows .. " rows")
  chk("<leader>no again cuts it", expand(buf, "long") == "jupynvim: output collapsed" and #region(buf, "long") == 500)

  -- ── a view leaves 'modified' alone ────────────────────────────────────
  changed(buf)
  chk("the notebook opens unmodified", not vim.bo[buf].modified)
  for _, what in ipairs({ "expanding", "cutting again" }) do
    expand(buf, "long"); changed(buf)
    chk(what .. " an output leaves a clean notebook unmodified", not vim.bo[buf].modified)
  end
  -- an edit, then a new view, and it is still modified
  local r = range(buf, "empty")
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, r.start, r.start + 1, false, { "x = 2" })
  changed(buf)
  chk("an edit marks it modified", vim.bo[buf].modified)
  expand(buf, "long"); changed(buf)
  chk("and expanding an output after it leaves it modified", vim.bo[buf].modified)
  chk("the edit survives the rewrite", vim.api.nvim_buf_get_lines(buf, range(buf, "empty").start,
      range(buf, "empty").start + 1, false)[1] == "x = 2")

  -- ── a save keeps every output, and the view comes back on open ────────
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  vim.wait(3000, function() return not vim.bo[buf].modified end, 20)
  local f = io.open(p); local saved = vim.json.decode(f:read("*a")); f:close()
  local by = {}
  for _, c in ipairs(saved.cells) do by[c.id] = c end
  local function joined(v) return type(v) == "table" and table.concat(v) or v end
  chk("the .ipynb keeps every printed line", by.long and joined(by.long.outputs[1].text) == printed(1000))
  chk("and the edit", by.empty and joined(by.empty.source) == "x = 2")
  local seq = vim.api.nvim_buf_call(buf, vim.fn.undotree).seq_last

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
  buf = open(p)
  chk("reopened, the long print is still expanded", #(region(buf, "long") or {}) == 1000)
  local ut = vim.api.nvim_buf_call(buf, vim.fn.undotree)
  chk("the undo history the save wrote is read back", #ut.entries > 0 and ut.seq_last == seq,
      ("%d entries, seq_last %d, saved at %d"):format(#ut.entries, ut.seq_last, seq))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()

  -- The file changes after the save, the way a run in JupyterLab or a git
  -- checkout changes it. The view was saved for the old text and goes.
  write_nb(p, 3000)
  buf = open(p)
  chk("opened on a file changed since the save, the long print is cut",
      #(region(buf, "long") or {}) == 500 and not cell(buf, "long")._output_expanded,
      #(region(buf, "long") or {}) .. " rows")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

-- ── a new run, and a collapse with nothing left to cut ───────────────────
do
  local p = tmp .. "/runs.ipynb"
  write_nb(p)
  local buf = open(p)
  -- a new run is a new output, cut again
  expand(buf, "long")
  event(buf, "long", { kind = "execute_input", execution_count = 2 })
  event(buf, "long", { kind = "stream", name = "stdout", text = printed(3000) })
  synced()
  chk("a new run cuts an expanded output again",
      #region(buf, "long") == 500 and not cell(buf, "long")._output_expanded, #region(buf, "long") .. " rows")

  -- cleared within the same run, it prints something short
  expand(buf, "long")
  event(buf, "long", { kind = "clear_output", wait = false })
  event(buf, "long", { kind = "stream", name = "stdout", text = "x\ny\n" })
  synced()
  chk("cut to nothing in the same run, it has nothing to collapse",
      expand(buf, "long") == "jupynvim: nothing to collapse", said())
  chk("and stops being expanded", not cell(buf, "long")._output_expanded)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

-- ── each notebook has its own views ──────────────────────────────────────
-- A copied .ipynb holds the same cell ids. Views kept by id in one table for
-- every notebook made one copy expand when the other did.
do
  local a, b = tmp .. "/a.ipynb", tmp .. "/b.ipynb"
  write_nb(a); write_nb(b)
  local ba = open(a)
  local bb = open(b)
  vim.api.nvim_set_current_buf(ba)
  local long_rows = #NB.output_lines(cell(bb, "long"))
  expand(ba, "long")
  chk("expanding in one copy leaves the other as it was", #NB.output_lines(cell(bb, "long")) == long_rows,
      ("%d rows, %d before"):format(#NB.output_lines(cell(bb, "long")), long_rows))
  expand(ba, "long")
  chk("and so does cutting it again", #NB.output_lines(cell(bb, "long")) == long_rows)
  pcall(vim.api.nvim_buf_delete, ba, { force = true })
  pcall(vim.api.nvim_buf_delete, bb, { force = true })
  Image.clear_all()
end

-- ── a view right after a change TextChanged has not seen ─────────────────
-- A cell op repopulates the buffer, which resets 'modified', and leaves it
-- to TextChanged to set it again. A view in between took the buffer for one
-- matching the file, and :q went on to drop the deleted cell.
do
  local p = tmp .. "/del.ipynb"
  write_nb(p)
  local buf = open(p)
  on(buf, "short")
  J.delete_cell(buf)
  vim.wait(3000, function() return #NB.get(buf).cells == 4 end, 20)
  chk("the delete leaves 'modified' to TextChanged", #NB.get(buf).cells == 4 and not vim.bo[buf].modified)
  expand(buf, "long")
  chk("a view right after it marks the notebook modified", vim.bo[buf].modified)
  changed(buf)
  chk("and TextChanged keeps it so", vim.bo[buf].modified)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

-- ── the key in the hint ──────────────────────────────────────────────────
do
  local p = tmp .. "/keys.ipynb"
  write_nb(p)
  local buf = open(p)
  chk("the hint key is the default one", K.lhs_for("expand_output", {}) == "<leader>no")
  chk("or the one the user bound",
      K.lhs_for("expand_output", { keymaps = { expand_output = "<leader>x" } }) == "<leader>x")
  chk("given as a table too",
      K.lhs_for("expand_output", { keymaps = { expand_output = { lhs = "<F7>" } } }) == "<F7>")
  chk("none when it is disabled", K.lhs_for("expand_output", { keymaps = { expand_output = false } }) == nil)
  chk("none when every default is off", K.lhs_for("expand_output", { disable_default_keymaps = true }) == nil)
  chk("none when it is bound outside normal mode",
      K.lhs_for("expand_output", { keymaps = { expand_output = { lhs = "<C-o>", mode = "i" } } }) == nil)
  local row = range(buf, "long").out_sep + 126
  J.config.keymaps = { expand_output = "<leader>x" }
  chk("the hint names a rebound key", hint(buf, row) == " <leader>x to expand", tostring(hint(buf, row)))
  J.config.keymaps = { expand_output = false }
  chk("with the key disabled the hint goes", hint(buf, row) == nil)
  J.config.keymaps = {}
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL OUTPUT-VIEW CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nOUTPUT-VIEW: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end
