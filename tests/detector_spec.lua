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

