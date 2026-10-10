-- How a cell shows its outputs, cut, expanded or hidden, #37.
--
-- <leader>no shows all of an output the cap cut, and cuts it again. On a plot
-- or a short print it changed nothing and still said "output expanded", which
-- read as broken. What the report wanted was to hide a plot, which is
-- <leader>nO now. Both are views of the cell. The .ipynb never sees them, they
-- leave 'modified' as it was, and a save keeps them, because the undo file
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
local ROWS = J.config.image_rows or 16

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
local function hide(buf, id) on(buf, id); J.toggle_output_hidden(buf); return said() end

-- Run what TextChanged runs after a keymap, which a headless run never
-- reaches on its own. That is where the buffer gets compared with the file.
local function changed(buf) vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf }) end

local function event(buf, id, ev)
  J._handle_cell_event({ session_id = NB.get(buf).session_id, cell_id = id, event = ev })
end
local function synced() vim.wait(600) end

local function plot_key(buf)
  return Image.output_key(Image.output_owner(buf or vim.api.nvim_get_current_buf(), "plot"), 1)
end
local function plot_rows(buf) return #Render._build_image_virt_lines(cell(buf, "plot"), 80, NB.get(buf), "") end
local function plot_sent(want, buf)
  vim.wait(3000, function() return (Image._placements[plot_key(buf)] ~= nil) == want end, 20)
  vim.wait(200)
  return Image._placements[plot_key(buf)] ~= nil
end

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
  chk("the plot is sent to the terminal on open", plot_sent(true))
  local before = text(buf)

  for _, id in ipairs({ "plot", "short", "empty", "how" }) do
    local msg = expand(buf, id)
    chk("<leader>no on " .. id .. " says there is nothing to expand",
        msg == "jupynvim: nothing to expand", tostring(msg))
    chk("and changes nothing on " .. id, text(buf) == before and not cell(buf, id)._output_expanded)
  end

  local rows = region(buf, "long")
  chk("a 1000-line print shows its first 500 lines, a marker and the last 5", #rows == 506, #rows .. " rows")
  chk("the marker says how many lines it hides, of how many",
      rows[501] == "  ⋯ 495 lines hidden (1000 total)", rows[501])
  chk("it hides exactly those lines",
      rows[500] == "  long line 500" and rows[502] == "  long line 996" and rows[506] == "  long line 1000",
      ("%s / %s / %s"):format(rows[500], rows[502], tostring(rows[506])))
  chk("the key to press follows the marker, outside the text",
      hint(buf, range(buf, "long").out_sep + 501) == " <leader>no to expand",
      tostring(hint(buf, range(buf, "long").out_sep + 501)))

  chk("<leader>no expands it", expand(buf, "long") == "jupynvim: output expanded", said())
  rows = region(buf, "long")
  chk("all 1000 lines show", #rows == 1000 and rows[1000] == "  long line 1000", #rows .. " rows")
  chk("<leader>no again cuts it", expand(buf, "long") == "jupynvim: output collapsed" and #region(buf, "long") == 506)

  -- ── <leader>nO hides the whole output, a plot included ─────────────────
  chk("<leader>nO hides the plot", hide(buf, "plot") == "jupynvim: output hidden", said())
  rows = region(buf, "plot")
  chk("one line says what is hidden", rows and #rows == 1 and rows[1] == "  ⋯ output hidden (1 image)",
      vim.inspect(rows))
  chk("the key to show it follows the line",
      hint(buf, range(buf, "plot").out_sep + 1) == " <leader>nO to show", tostring(hint(buf, range(buf, "plot").out_sep + 1)))
  chk("no rows are kept for the image", plot_rows(buf) == 0, plot_rows(buf) .. " rows")
  chk("the terminal lets the image go", not plot_sent(false))
  chk("<leader>no on a hidden output points at <leader>nO",
      expand(buf, "plot") == "jupynvim: output is hidden, <leader>nO shows it", said())
  chk("<leader>nO shows it again", hide(buf, "plot") == "jupynvim: output shown" and region(buf, "plot") == nil,
      said())
  chk("the image is sent again", plot_sent(true) and plot_rows(buf) == ROWS, plot_rows(buf) .. " rows")

  chk("<leader>nO hides a long print", hide(buf, "long") == "jupynvim: output hidden")
  rows = region(buf, "long")
  chk("and counts its lines", #rows == 1 and rows[1] == "  ⋯ output hidden (1000 lines)", vim.inspect(rows))
  chk("shown again, it is cut as before", hide(buf, "long") == "jupynvim: output shown" and #region(buf, "long") == 506)
  expand(buf, "long"); hide(buf, "long"); hide(buf, "long")
  chk("an expanded output comes back expanded", #region(buf, "long") == 1000)
  expand(buf, "long")

  chk("<leader>nO with no output says there is nothing to hide",
      hide(buf, "empty") == "jupynvim: nothing to hide" and not cell(buf, "empty")._output_hidden, said())
  chk("so does it on a markdown cell", hide(buf, "how") == "jupynvim: nothing to hide", said())

  -- ── views leave 'modified' alone ──────────────────────────────────────
  changed(buf)
  chk("the notebook opens unmodified", not vim.bo[buf].modified)
  for _, step in ipairs({ { expand, "long", "expanding" }, { expand, "long", "cutting again" },
                          { hide, "plot", "hiding" }, { hide, "plot", "showing" } }) do
    step[1](buf, step[2]); changed(buf)
    chk(step[3] .. " an output leaves a clean notebook unmodified", not vim.bo[buf].modified)
  end
  -- an edit, then a new view, and it is still modified
  local r = range(buf, "empty")
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, r.start, r.start + 1, false, { "x = 2" })
  changed(buf)
  chk("an edit marks it modified", vim.bo[buf].modified)
  hide(buf, "plot"); changed(buf)
  chk("and hiding an output after it leaves it modified", vim.bo[buf].modified)
  chk("the edit survives the rewrite", vim.api.nvim_buf_get_lines(buf, range(buf, "empty").start,
      range(buf, "empty").start + 1, false)[1] == "x = 2")

  -- ── a save keeps every output, and the views come back on open ─────────
  expand(buf, "long")
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  vim.wait(3000, function() return not vim.bo[buf].modified end, 20)
  local f = io.open(p); local saved = vim.json.decode(f:read("*a")); f:close()
  local by = {}
  for _, c in ipairs(saved.cells) do by[c.id] = c end
  local function joined(v) return type(v) == "table" and table.concat(v) or v end
  chk("the .ipynb keeps the hidden plot", by.plot and #by.plot.outputs == 1
      and joined(by.plot.outputs[1].data["image/png"]) == PLOT)
  chk("and every printed line", by.long and joined(by.long.outputs[1].text) == printed(1000))
  chk("and the edit", by.empty and joined(by.empty.source) == "x = 2")
  local seq = vim.api.nvim_buf_call(buf, vim.fn.undotree).seq_last

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
  buf = open(p)
  rows = region(buf, "plot")
  chk("reopened, the plot is still hidden", cell(buf, "plot")._output_hidden
      and rows and rows[1] == "  ⋯ output hidden (1 image)", vim.inspect(rows))
  chk("and the long print still expanded", #(region(buf, "long") or {}) == 1000)
  local ut = vim.api.nvim_buf_call(buf, vim.fn.undotree)
  chk("the undo history the save wrote is read back", #ut.entries > 0 and ut.seq_last == seq,
      ("%d entries, seq_last %d, saved at %d"):format(#ut.entries, ut.seq_last, seq))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()

  -- The file changes after the save, the way a run in JupyterLab or a git
  -- checkout changes it. The views were saved for the old text and go.
  write_nb(p, 3000)
  buf = open(p)
  chk("opened on a file changed since the save, the long print is cut",
      #(region(buf, "long") or {}) == 506 and not cell(buf, "long")._output_expanded,
      #(region(buf, "long") or {}) .. " rows")
  chk("and the plot shows", not cell(buf, "plot")._output_hidden and region(buf, "plot") == nil)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

-- ── a run while hidden, a collapse with nothing left to cut ──────────────
do
  local p = tmp .. "/runs.ipynb"
  write_nb(p)
  local buf = open(p)
  hide(buf, "short")
  event(buf, "short", { kind = "execute_input", execution_count = 2 })
  event(buf, "short", { kind = "stream", name = "stdout", text = "a\nb\nc\n" })
  synced()
  local rows = region(buf, "short")
  chk("a run while hidden stays hidden, and recounts", rows and #rows == 1
      and rows[1] == "  ⋯ output hidden (3 lines)", vim.inspect(rows))

  -- a new run is a new output, cut again
  expand(buf, "long")
  event(buf, "long", { kind = "execute_input", execution_count = 2 })
  event(buf, "long", { kind = "stream", name = "stdout", text = printed(3000) })
  synced()
  chk("a new run cuts an expanded output again",
      #region(buf, "long") == 506 and not cell(buf, "long")._output_expanded, #region(buf, "long") .. " rows")

  -- cleared within the same run, it prints something short
  expand(buf, "long")
  event(buf, "long", { kind = "clear_output", wait = false })
  event(buf, "long", { kind = "stream", name = "stdout", text = "x\ny\n" })
  synced()
  chk("cut to nothing in the same run, it has nothing to collapse",
      expand(buf, "long") == "jupynvim: nothing to collapse", said())
  chk("and stops being expanded", not cell(buf, "long")._output_expanded)

  on(buf, "short"); J.clear_cell_output(buf); vim.wait(200)
  chk("a hidden output cleared away has nothing to show", hide(buf, "short") == "jupynvim: nothing to show",
      said())
  chk("and no longer hidden", not cell(buf, "short")._output_hidden)
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
  local short_rows = #NB.output_lines(cell(bb, "short"))
  expand(ba, "long")
  hide(ba, "short")
  chk("expanding in one copy leaves the other as it was", #NB.output_lines(cell(bb, "long")) == long_rows,
      ("%d rows, %d before"):format(#NB.output_lines(cell(bb, "long")), long_rows))
  chk("hiding in one copy leaves the other as it was", #NB.output_lines(cell(bb, "short")) == short_rows)
  expand(ba, "long")
  chk("and so does cutting it again", #NB.output_lines(cell(bb, "long")) == long_rows)
  on(ba, "long"); J.limit_output(ba, 100)
  chk("a number of lines in one copy leaves the other as it was",
      #NB.output_lines(cell(ba, "long")) == 106 and #NB.output_lines(cell(bb, "long")) == long_rows)
  -- the images too: owned by the cell id alone, hiding the plot in one copy
  -- freed the other copy's
  chk("the other copy's plot is in the terminal", plot_sent(true, bb))
  hide(ba, "plot")
  Render.refresh_sync(NB.get(ba), vim.fn.bufwinid(ba))
  vim.wait(300)
  chk("hiding the plot in one copy keeps the other copy's image",
      Image._placements[plot_key(bb)] ~= nil and plot_rows(bb) == ROWS, plot_rows(bb) .. " rows")
  pcall(vim.api.nvim_buf_delete, ba, { force = true })
  pcall(vim.api.nvim_buf_delete, bb, { force = true })
  Image.clear_all()
end

-- ── a key acts on the cell the buffer shows ──────────────────────────────
-- After :undo N an output can show its older view until the next edit. Laid
-- out from the cells instead of the buffer, every line below it named
-- another cell, and <leader>nO on the cell under the print hid the print.
do
  local p = tmp .. "/jump.ipynb"
  write_nb(p)
  local buf = open(p)
  expand(buf, "long")
  vim.bo[buf].modifiable = true
  vim.cmd("silent undo 0")
  changed(buf)
  chk("after :undo 0 the long print shows cut", #(region(buf, "long") or {}) == 506,
      #(region(buf, "long") or {}) .. " rows")
  local msg = hide(buf, "empty")
  chk("<leader>nO on the cell below it acts on that cell", msg == "jupynvim: nothing to hide", tostring(msg))
  chk("and leaves the long print alone", not cell(buf, "long")._output_hidden)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
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
  hide(buf, "plot")
  chk("a view right after it marks the notebook modified", vim.bo[buf].modified)
  changed(buf)
  chk("and TextChanged keeps it so", vim.bo[buf].modified)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

-- ── <leader>nl gives a cell its own number of lines ─────────────────────
do
  local p = tmp .. "/limit.ipynb"
  write_nb(p)
  local buf = open(p)
  local real_input = vim.ui.input
  local asked
  vim.ui.input = function(opts, cb) asked = opts.prompt; cb("100") end
  on(buf, "long"); J.limit_output(buf)
  vim.ui.input = real_input
  chk("<leader>nl asks how many lines, saying how many show now", asked == "Show how many lines (now 500)? ",
      tostring(asked))
  chk("and says what it did", said() == "jupynvim: output cut to its first 100 lines", said())
  local rows = region(buf, "long")
  chk("the output shows its first 100 lines, a marker and the last 5", #rows == 106
      and rows[100] == "  long line 100" and rows[101] == "  ⋯ 895 lines hidden (1000 total)"
      and rows[106] == "  long line 1000", #rows .. " rows")
  chk("the key to expand follows its marker", hint(buf, range(buf, "long").out_sep + 101) == " <leader>no to expand")
  chk("<leader>no then shows every line",
      expand(buf, "long") == "jupynvim: output expanded" and #region(buf, "long") == 1000)
  chk("and cuts back to the cell's 100",
      expand(buf, "long") == "jupynvim: output collapsed" and #region(buf, "long") == 106)
  vim.ui.input = function(opts, cb) asked = opts.prompt; cb(nil) end
  local before = text(buf)
  on(buf, "long"); J.limit_output(buf)
  vim.ui.input = real_input
  chk("asked again, it says the cell's number", asked == "Show how many lines (now 100)? ", tostring(asked))
  chk("and cancelling changes nothing", text(buf) == before and cell(buf, "long")._output_limit == 100)
  for _, bad in ipairs({ "abc", "0", "-3", "1.5" }) do
    on(buf, "long"); J.limit_output(buf, bad)
    chk(("%q is refused"):format(bad), said() == "jupynvim: give a whole number of lines, like 100"
        and cell(buf, "long")._output_limit == 100, said())
  end

  on(buf, "short"); J.limit_output(buf, 50)
  chk("a number past a short output cuts nothing, and says so",
      said() == "jupynvim: nothing to cut, it has 5 lines" and #region(buf, "short") == 5, said())
  on(buf, "empty"); J.limit_output(buf, 50)
  chk("a cell with no output keeps the number for its next one", said() == "jupynvim: nothing to cut yet"
      and cell(buf, "empty")._output_limit == 50, said())
  on(buf, "how"); J.limit_output(buf, 50)
  chk("a markdown cell has no output to cut", said() == "jupynvim: not a code cell", said())
  hide(buf, "long")
  on(buf, "long"); J.limit_output(buf, 200)
  chk("a number shows a hidden output again, cut to it", not cell(buf, "long")._output_hidden
      and #region(buf, "long") == 206, #region(buf, "long") .. " rows")
  changed(buf)
  chk("none of it marks the notebook modified", not vim.bo[buf].modified)

  -- what a save keeps
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  vim.wait(3000, function() return not vim.bo[buf].modified end, 20)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
  buf = open(p)
  chk("reopened, the cell keeps its number", cell(buf, "long")._output_limit == 200
      and #(region(buf, "long") or {}) == 206, #(region(buf, "long") or {}) .. " rows")
  local ut = vim.api.nvim_buf_call(buf, vim.fn.undotree)
  chk("and the undo history is read back", #ut.entries > 0)

  -- These events reach the cells here but not the backend, so nothing is
  -- saved after them.
  event(buf, "long", { kind = "execute_input", execution_count = 2 })
  event(buf, "long", { kind = "stream", name = "stdout", text = printed(3000) })
  synced()
  chk("a new run keeps the cell's number", #region(buf, "long") == 206, #region(buf, "long") .. " rows")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

-- ── the keys ─────────────────────────────────────────────────────────────
do
  local p = tmp .. "/keys.ipynb"
  write_nb(p)
  local buf = open(p)
  on(buf, "how")
  J.jump_image(buf, 1)
  chk("]i lands on the plot", CM.cell_idx_at(buf, vim.api.nvim_win_get_cursor(0)[1]) == idx(buf, "plot"))
  hide(buf, "plot")
  on(buf, "how")
  J.jump_image(buf, 1)
  chk("and passes it by while it is hidden",
      CM.cell_idx_at(buf, vim.api.nvim_win_get_cursor(0)[1]) ~= idx(buf, "plot"))
  hide(buf, "plot")
  local ml = vim.fn.maparg("<leader>nl", "n", false, true)
  chk("<leader>nl is bound in a notebook", ml.buffer == 1 and ml.desc == "Show N lines of cell output",
      vim.inspect(ml.desc))
  local m = vim.fn.maparg("<leader>nO", "n", false, true)
  chk("<leader>nO is bound in a notebook", m.buffer == 1 and m.desc == "Hide/show cell output", vim.inspect(m.desc))
  chk("the hint key is the default one", K.lhs_for("hide_output", {}) == "<leader>nO")
  chk("or the one the user bound", K.lhs_for("hide_output", { keymaps = { hide_output = "<leader>x" } }) == "<leader>x")
  chk("given as a table too",
      K.lhs_for("expand_output", { keymaps = { expand_output = { lhs = "<F7>" } } }) == "<F7>")
  chk("none when it is disabled", K.lhs_for("hide_output", { keymaps = { hide_output = false } }) == nil)
  chk("none when every default is off", K.lhs_for("hide_output", { disable_default_keymaps = true }) == nil)
  chk("none when it is bound outside normal mode",
      K.lhs_for("hide_output", { keymaps = { hide_output = { lhs = "<C-o>", mode = "i" } } }) == nil)
  -- the hint and the message name the key that is bound
  J.config.keymaps = { hide_output = "<leader>x" }
  hide(buf, "plot")
  chk("the hint names a rebound key", hint(buf, range(buf, "plot").out_sep + 1) == " <leader>x to show",
      tostring(hint(buf, range(buf, "plot").out_sep + 1)))
  chk("and so does the message", expand(buf, "plot") == "jupynvim: output is hidden, <leader>x shows it", said())
  J.config.keymaps = { hide_output = false }
  chk("with the key disabled the hint goes", hint(buf, range(buf, "plot").out_sep + 1) == nil)
  chk("and the message names none", expand(buf, "plot") == "jupynvim: output is hidden", said())
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
