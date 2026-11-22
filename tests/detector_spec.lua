local T = _G.TestHarness
local detector = require("mermaid_lens.parser.detector")

T.test("detector.detect_diagram_type detects canonical types", function()
	T.assert_eq(detector.detect_diagram_type("flowchart TD\n  A --> B"), "flowchart")
	T.assert_eq(detector.detect_diagram_type("graph LR\n  A --> B"), "flowchart")
	T.assert_eq(detector.detect_diagram_type("sequenceDiagram\n  Alice->>Bob: Hello"), "sequenceDiagram")
	T.assert_eq(detector.detect_diagram_type("classDiagram\n  class Animal"), "classDiagram")
	T.assert_eq(detector.detect_diagram_type("erDiagram\n  CUSTOMER ||--o{ ORDER : places"), "erDiagram")
	T.assert_eq(detector.detect_diagram_type("stateDiagram-v2\n  [*] --> Still"), "stateDiagram-v2")
	T.assert_eq(detector.detect_diagram_type("gantt\n  title Project"), "gantt")
	T.assert_eq(detector.detect_diagram_type("gitGraph\n  commit"), "gitGraph")
	T.assert_eq(detector.detect_diagram_type("mindmap\n  root((Root))"), "mindmap")
end)

T.test("detector.detect_diagram_type skips YAML frontmatter and comments", function()
	local code = [[---
title: Sample Architecture
config:
  theme: forest
---
%% this is a comment
%% another comment
flowchart TD
  Start --> Stop]]
	T.assert_eq(detector.detect_diagram_type(code), "flowchart")
end)

T.test("detector.extract_explicit_name handles header names and comments", function()
	local name1, ok1 = detector.extract_explicit_name("mermaid auth_flow", "sequenceDiagram\nAlice->>Bob: Hi")
	T.assert_true(ok1)
	T.assert_eq(name1, "auth_flow")

	local name2, ok2 = detector.extract_explicit_name("mermaid", "flowchart TD\n%% name: pipeline\nA --> B")
	T.assert_true(ok2)
	T.assert_eq(name2, "pipeline")

	local name3, ok3 = detector.extract_explicit_name("mermaid", "flowchart TD\nA --> B")
	T.assert_true(ok3)
	T.assert_nil(name3)

	local _, ok_py = detector.extract_explicit_name("python", "print('hello')")
	T.assert_false(ok_py)
end)

T.test("detector.scan_fenced_blocks parses standard 3-backtick Mermaid blocks", function()
	local lines = {
		"# Title",
		"",
		"```mermaid architecture",
		"flowchart TD",
		"  Client --> Server",
		"```",
		"",
		"Some text between.",
		"",
		"```mermaid",
		"sequenceDiagram",
		"  Client->>Server: Request",
		"```",
	}

	local blocks = detector.scan_fenced_blocks(lines)
	T.assert_eq(#blocks, 2)

	T.assert_eq(blocks[1].open_lnum, 3)
	T.assert_eq(blocks[1].close_lnum, 6)
	T.assert_eq(blocks[1].explicit_name, "architecture")
	T.assert_eq(blocks[1].diagram_type, "flowchart")

	T.assert_eq(blocks[2].open_lnum, 10)
	T.assert_eq(blocks[2].close_lnum, 13)
	T.assert_nil(blocks[2].explicit_name)
	T.assert_eq(blocks[2].diagram_type, "sequenceDiagram")
end)

T.test("detector.scan_fenced_blocks ignores non-mermaid blocks", function()
	local lines = {
		"```lua",
		"local x = 10",
		"```",
		"```mermaid",
		"flowchart TD",
		"  A --> B",
		"```",
	}
	local blocks = detector.scan_fenced_blocks(lines)
	T.assert_eq(#blocks, 1)
	T.assert_eq(blocks[1].open_lnum, 4)
	T.assert_eq(blocks[1].close_lnum, 7)
end)
T.test("detector.scan_fenced_blocks supports CommonMark 4-backtick and tilde fences", function()
	local lines = {
		"````mermaid four_ticks",
		"flowchart TD",
		"  A[\"```inner backticks```\"] --> B",
		"````",
		"",
		"~~~mermaid tilde_fence",
		"sequenceDiagram",
		"  Alice->>Bob: Hello",
		"~~~",
	}
	local blocks = detector.scan_fenced_blocks(lines)
	T.assert_eq(#blocks, 2)

	T.assert_eq(blocks[1].open_lnum, 1)
	T.assert_eq(blocks[1].close_lnum, 4)
	T.assert_eq(blocks[1].explicit_name, "four_ticks")
	T.assert_eq(blocks[1].diagram_type, "flowchart")

	T.assert_eq(blocks[2].open_lnum, 6)
	T.assert_eq(blocks[2].close_lnum, 9)
	T.assert_eq(blocks[2].explicit_name, "tilde_fence")
	T.assert_eq(blocks[2].diagram_type, "sequenceDiagram")
end)

T.test("detector.detect_diagram_type rejects common code identifiers with prefix collisions", function()
	local false_positives = {
		"piece = 1",
		"gantt_chart = {}",
		"timeline_items = []",
		"journey_id = 42",
		"kanban_board = true",
		"mindmap_node = 1",
		"sankey_data = {}",
		"xychart_config = {}",
	}

	for _, snippet in ipairs(false_positives) do
		T.assert_nil(detector.detect_diagram_type(snippet), "Must not classify as Mermaid: " .. snippet)
	end

	T.assert_eq(detector.detect_diagram_type("pie\n  \"A\" : 10"), "pie")
	T.assert_eq(detector.detect_diagram_type("pie title Pets\n  \"Dogs\" : 5"), "pie")
	T.assert_eq(detector.detect_diagram_type("gantt\n  title Plan"), "gantt")
	T.assert_eq(detector.detect_diagram_type("journey\n  title Day"), "journey")
end)

T.test("detector.extract_explicit_name rejects non-mermaid info strings", function()
	local name_py, ok_py = detector.extract_explicit_name("python", "piece = 1")
	T.assert_nil(name_py)
	T.assert_false(ok_py)

	local name_yaml, ok_yaml = detector.extract_explicit_name("yaml", "pie: true")
	T.assert_nil(name_yaml)
	T.assert_false(ok_yaml)

	local name_js, ok_js = detector.extract_explicit_name("mermaidjs", "flowchart TD\nA-->B")
	T.assert_nil(name_js)
	T.assert_false(ok_js)
end)

T.test("detector.scan_fenced_blocks keeps explicit mermaid fence with line-1 typo and ignores python", function()
	local lines = {
		"```python",
		"piece = 1",
		"```",
		"```mermaid broken_chart",
		"flowchrat TD",
		"  A --> B",
		"```",
	}

	local blocks = detector.scan_fenced_blocks(lines)

	T.assert_eq(#blocks, 1)
	T.assert_eq(blocks[1].open_lnum, 4)
	T.assert_eq(blocks[1].close_lnum, 7)
	T.assert_eq(blocks[1].explicit_name, "broken_chart")
	T.assert_eq(blocks[1].diagram_type, "mermaid")
end)


