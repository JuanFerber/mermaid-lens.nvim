--- @module mermaid_lens.graphics.kitty
--- Architectural Layer: Infrastructure / Interface Adapter
--- Parent: `mermaid_lens.ui.modal` and `mermaid_lens.ui.loader`
--- Children: `mermaid_lens.env.multiplexer`
--- Single Responsibility: Encode and transmit Kitty Graphics Protocol APC escape
--- sequences with atomic cursor preservation (`DECSC`/`DECRC` + `C=1`).

local multiplexer = require("mermaid_lens.env.multiplexer")

local M = {}

--- @class KittyViewportPlacement
--- @field img_id integer Unique texture identifier in GPU memory
--- @field x integer Source crop top-left X coordinate in pixels
--- @field y integer Source crop top-left Y coordinate in pixels
--- @field w integer Source crop width in pixels
--- @field h integer Source crop height in pixels
--- @field cols integer Destination width in terminal character cells
--- @field rows integer Destination height in terminal character cells
--- @field screen_row integer 1-based absolute terminal row
--- @field screen_col integer 1-based absolute terminal column

local function build_apc(params, payload)
	local parts = {}
	for k, v in pairs(params) do
		table.insert(parts, string.format("%s=%s", k, tostring(v)))
	end
	local header = table.concat(parts, ",")
	return string.format("\x1b_G%s;%s\x1b\\", header, payload or "")
end

--- Sends a single Kitty APC command wrapped for the active multiplexer.
--- @param params table<string, string|number>
--- @param payload string|nil
function M.send(params, payload)
	local seq = multiplexer.wrap_passthrough(build_apc(params, payload))
	vim.api.nvim_chan_send(vim.v.stderr, seq)
end

--- Uploads a local PNG file to Kitty's GPU texture slot `img_id`.
--- @param img_id integer
--- @param png_path string
function M.transmit_file(img_id, png_path)
	multiplexer.ensure_configured()
	local b64_path = vim.base64.encode(png_path)
	M.send({ a = "t", f = 100, t = "f", i = img_id, q = 2 }, b64_path)
end

--- Renders a cropped rectangular region of texture `img_id` at exact screen coordinates.
--- Saves and restores the cursor (`\x1b7` / `\x1b8`) inside the passthrough envelope
--- and sets `C=1` so Kitty never mutates Neovim's physical cursor position.
--- @param opts KittyViewportPlacement
function M.place_viewport(opts)
	local apc = build_apc({
		a = "p",
		i = opts.img_id,
		p = 1,
		C = 1,
		x = opts.x,
		y = opts.y,
		w = opts.w,
		h = opts.h,
		c = opts.cols,
		r = opts.rows,
		q = 2,
	})

	local raw_seq = string.format("\x1b7\x1b[%d;%dH%s\x1b8", opts.screen_row, opts.screen_col, apc)
	vim.api.nvim_chan_send(vim.v.stderr, multiplexer.wrap_passthrough(raw_seq))
end

--- Clears all visible image placements on the active screen without freeing GPU memory.
function M.clear_all_placements()
	M.send({ a = "d", d = "a", q = 2 })
end

--- Deletes texture `img_id` completely from GPU memory.
--- @param img_id integer
function M.delete_image(img_id)
	M.send({ a = "d", d = "I", i = img_id, q = 2 })
end

return M
