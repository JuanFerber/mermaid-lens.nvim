local T = _G.TestHarness
local camera_mod = require("mermaid_lens.graphics.camera")
local viewport = require("mermaid_lens.graphics.viewport")

T.test("graphics.viewport respects injected editor_layout independently of global Vim options", function()
	local ucols, urows, tab_h = viewport.get_usable_editor_area(120, 40, { tabline_h = 0, bottom_h = 1 })
	T.assert_eq(ucols, 120)
	T.assert_eq(urows, 39)
	T.assert_eq(tab_h, 0)

	local row, col = viewport.compute_centered_position(40, 10, nil, {
		ui_cols = 100,
		ui_rows = 30,
		tabline_h = 1,
		bottom_h = 2,
	})
	T.assert_eq(row, 8)
	T.assert_eq(col, 29)
end)

T.test("graphics.camera zooms around center, pans, drags, toggles fit, and computes bounded tile crops", function()
	local metrics = { cell_w = 10, cell_h = 20, tmux_top = 0, tmux_left = 0 }
	local cam = camera_mod.new()

	cam:apply_image(600, 3000, 100, 40, metrics, true)
	T.assert_eq(cam.zoom, 1.0)
	T.assert_true(cam.smart_zoom > 1.5)

	local before = cam:project(100, 40, metrics)
	local cx_before = before.pan_x + before.cam_w / 2
	local cy_before = before.pan_y + before.cam_h / 2

	cam:zoom_by(1, 100, 40, metrics)
	local after = cam:project(100, 40, metrics)
	T.assert_true(cam.zoom > 1.0)
	T.assert_true(math.abs((after.pan_x + after.cam_w / 2) - cx_before) < 1.0)
	T.assert_true(math.abs((after.pan_y + after.cam_h / 2) - cy_before) < 1.0)

	local p0_x = cam.pan_x
	cam:pan(1, 0, 100, 40, metrics)
	T.assert_true(cam.pan_x > p0_x)

	local p1_x = cam.pan_x
	cam:drag_cells(-4, 0, 100, 40, metrics)
	T.assert_true(cam.pan_x < p1_x)

	cam:reset(100, 40, metrics)
	T.assert_eq(cam.zoom, 1.0)

	cam:toggle_fit(100, 40, metrics)
	T.assert_true(cam.zoom > 1.5)
	cam:toggle_fit(100, 40, metrics)
	T.assert_eq(cam.zoom, 1.0)

	cam:zoom_by(1, 100, 40, metrics)
	local req = cam:compute_tile_request(100, 40, metrics, 1024)
	T.assert_true(req.crop.x >= 0 and req.crop.y >= 0)
	T.assert_true(req.crop.x + req.crop.w <= 600 and req.crop.y + req.crop.h <= 3000)
	T.assert_true(req.raster_w <= 1024 and req.raster_h <= 1024)
end)
