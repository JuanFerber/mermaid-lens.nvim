local T = _G.TestHarness
local viewport = require("mermaid_lens.graphics.viewport")
local cache = require("mermaid_lens.renderer.cache")
local constants = require("mermaid_lens.config.constants")

T.test("graphics.viewport.compute_centered_position calculates exact coordinates for parent_box and screen", function()
	-- 1. Exact centering within parent_box
	local parent = { row = 10, col = 20, width = 80, height = 40 }
	local row, col = viewport.compute_centered_position(40, 10, parent)
	-- row: 10 + floor(((40 + 2) - (10 + 2)) / 2) = 10 + 15 = 25
	-- col: 20 + floor(((80 + 2) - (40 + 2)) / 2) = 20 + 20 = 40
	T.assert_eq(row, 25)
	T.assert_eq(col, 40)

	-- 2. Centering relative to usable screen
	local usable_cols, usable_rows, tabline_h = viewport.get_usable_editor_area()
	local s_row, s_col = viewport.compute_centered_position(50, 20)
	local expected_row = tabline_h + math.max(0, math.floor((usable_rows - (20 + 2)) / 2))
	local expected_col = math.max(0, math.floor((usable_cols - (50 + 2)) / 2))
	T.assert_eq(s_row, expected_row)
	T.assert_eq(s_col, expected_col)
end)

T.test("graphics.viewport.compute_smart_initial_zoom triggers for tall diagrams and stays 1.0 for wide diagrams", function()
	local metrics = { cell_w = 10, cell_h = 20 }

	-- Wide diagram fills width: fit_cols = 100, trigger ratio is 55, should return MIN_ZOOM (1.0)
	local wide_zoom = viewport.compute_smart_initial_zoom(100, 50, 2000, 1000, metrics)
	T.assert_eq(wide_zoom, constants.LIMITS.MIN_ZOOM)

	-- Tall diagram: fit_cols = 10, triggers smart zoom to 8.2
	local tall_zoom = viewport.compute_smart_initial_zoom(100, 50, 200, 2000, metrics)
	T.assert_eq(tall_zoom, 8.2)
end)

T.test("renderer.cache.resolve_paths generates deterministic paths", function()
	local diagram = {
		name = "test_diag",
		code = "flowchart TD\n  A --> B",
	}
	local p1 = cache.resolve_paths(diagram, "light")
	local p2 = cache.resolve_paths(diagram, "light")
	local p3 = cache.resolve_paths(diagram, "dark")

	T.assert_eq(p1.png_path, p2.png_path)
	T.assert_true(p1.png_path:find("light_test_diag_", 1, true) ~= nil)
	T.assert_true(p3.png_path:find("dark_test_diag_", 1, true) ~= nil)
end)

T.test("renderer.cache.read_png_dimensions handles missing and non-png files safely", function()
	local w, h = cache.read_png_dimensions("/path/to/nonexistent/file.png")
	T.assert_nil(w)
	T.assert_nil(h)
end)
