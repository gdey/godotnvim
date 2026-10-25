package main

import (
	"fmt"
	"math"
	"strconv"
)

// A source is a highlight group attribute: "Group" means its foreground,
// "Group.bg" its background.
type rule struct {
	key     string   // below text_editor/theme/highlighting/
	sources []string // first one set wins
	alpha   uint8    // 0xff unless the color should be translucent
}

// rules maps Neovim highlight groups onto Godot's script-editor colors.
// Treesitter groups come first: they are the more specific, and Neovim links
// them to the legacy groups when a scheme only sets those.
var rules = []rule{
	{"background_color", []string{"Normal.bg"}, 0xff},
	{"text_color", []string{"Normal"}, 0xff},
	{"symbol_color", []string{"@operator", "Operator", "Delimiter", "Normal"}, 0xff},
	{"keyword_color", []string{"@keyword", "Keyword", "Statement"}, 0xff},
	{"control_flow_keyword_color", []string{"@keyword.conditional", "Conditional", "@keyword", "Statement"}, 0xff},
	{"base_type_color", []string{"@type.builtin", "@type", "Type"}, 0xff},
	{"engine_type_color", []string{"@type", "Type"}, 0xff},
	{"user_type_color", []string{"@type", "Type"}, 0xff},
	{"comment_color", []string{"@comment", "Comment"}, 0xff},
	{"doc_comment_color", []string{"@comment.documentation", "SpecialComment", "@comment", "Comment"}, 0xff},
	{"string_color", []string{"@string", "String"}, 0xff},
	{"number_color", []string{"@number", "Number", "Constant"}, 0xff},
	{"function_color", []string{"@function.call", "@function", "Function"}, 0xff},
	{"member_variable_color", []string{"@variable.member", "@property", "Identifier", "Normal"}, 0xff},

	{"gdscript/function_definition_color", []string{"@function", "Function"}, 0xff},
	{"gdscript/global_function_color", []string{"@function.builtin", "@function", "Function"}, 0xff},
	{"gdscript/node_path_color", []string{"@string.special.path", "@string.special", "Special"}, 0xff},
	{"gdscript/node_reference_color", []string{"@string.special.path", "@string.special", "Special"}, 0xff},
	{"gdscript/annotation_color", []string{"@attribute", "PreProc"}, 0xff},
	{"gdscript/string_name_color", []string{"@string.special.symbol", "@string", "String"}, 0xff},

	// Godot colors the marker word; schemes often draw @comment.error and Todo
	// as badges, so their foreground is the background color.
	{"comment_markers/critical_color", []string{"DiagnosticError", "Error", "@comment.error"}, 0xff},
	{"comment_markers/warning_color", []string{"DiagnosticWarn", "WarningMsg", "Todo.bg"}, 0xff},
	{"comment_markers/notice_color", []string{"DiagnosticInfo", "Todo.bg"}, 0xff},

	{"completion_background_color", []string{"Pmenu.bg", "NormalFloat.bg", "Normal.bg"}, 0xff},
	{"completion_selected_color", []string{"PmenuSel.bg", "Visual.bg"}, 0xff},
	{"completion_existing_color", []string{"PmenuMatch", "@function", "Function"}, 0x33},
	{"completion_scroll_color", []string{"PmenuThumb.bg", "PmenuSbar.bg"}, 0xff},
	{"completion_scroll_hovered_color", []string{"PmenuThumb.bg", "PmenuSbar.bg"}, 0xff},
	{"completion_font_color", []string{"Pmenu", "Normal"}, 0xff},

	{"line_number_color", []string{"LineNr", "Comment"}, 0xff},
	{"safe_line_number_color", []string{"@string", "String"}, 0x80},
	{"caret_color", []string{"Cursor.bg", "Normal"}, 0xff},
	{"caret_background_color", []string{"Normal.bg"}, 0xff},
	{"selection_color", []string{"Visual.bg"}, 0xff},
	{"brace_mismatch_color", []string{"DiagnosticError", "Error"}, 0xff},
	{"current_line_color", []string{"CursorLine.bg"}, 0xff},
	{"line_length_guideline_color", []string{"ColorColumn.bg", "CursorLine.bg"}, 0xff},
	{"word_highlighted_color", []string{"LspReferenceText.bg", "CursorLine.bg", "Visual.bg"}, 0xff},
	{"mark_color", []string{"DiagnosticError", "Error"}, 0x40},
	{"warning_color", []string{"DiagnosticWarn", "WarningMsg"}, 0x1a},
	{"bookmark_color", []string{"DiagnosticInfo", "Function"}, 0xff},
	{"breakpoint_color", []string{"DiagnosticError", "Error"}, 0xff},
	{"executing_line_color", []string{"DiagnosticWarn", "WarningMsg"}, 0xff},
	{"code_folding_color", []string{"Folded", "Comment"}, 0xff},
	{"folded_code_region_color", []string{"Folded.bg", "CursorLine.bg"}, 0xff},
	// Godot draws search hits under the text, so an opaque Search would hide it.
	{"search_result_color", []string{"Search.bg", "IncSearch.bg"}, 0x40},
	{"search_result_border_color", []string{"Search.bg", "IncSearch.bg"}, 0xff},
}

// Theme is a Godot editor theme: script-editor colors plus the interface
// base and accent colors Godot derives the rest of the editor from.
type Theme struct {
	Name       string
	Background string            // "dark" or "light"
	Colors     map[string]string // key below text_editor/theme/highlighting/ -> "rrggbbaa"
	Base       string            // "rrggbb"
	Accent     string            // "rrggbb"
}

// Convert maps a palette onto a Godot theme.
func Convert(name string, p *Palette) (*Theme, error) {
	g := resolve(p)
	if g.attr("Normal.bg") == "" {
		return nil, fmt.Errorf("%s: Normal has no background (a transparent scheme), nothing to put behind the code", name)
	}
	t := &Theme{Name: name, Background: p.Background, Colors: map[string]string{}}
	for _, r := range rules {
		c := ""
		for _, s := range r.sources {
			if c = g.attr(s); c != "" {
				break
			}
		}
		if c == "" {
			c = fallback(r.key, g)
		}
		t.Colors[r.key] = c + fmt.Sprintf("%02x", r.alpha)
	}
	// Transparent keeps the syntax colors inside a selection.
	t.Colors["text_selected_color"] = g.attr("Normal.bg") + "00"
	t.Base = base(g)
	t.Accent = accent(g)
	return t, nil
}

// groups are highlight groups with reverse applied and Normal filled in.
type groups map[string]Highlight

func resolve(p *Palette) groups {
	normal := p.Groups["Normal"]
	if normal.Fg == "" {
		normal.Fg = map[bool]string{true: "e0e2ea", false: "14161b"}[p.Background != "light"]
	}
	g := groups{}
	for name, h := range p.Groups {
		if h.Reverse {
			fg, bg := h.Fg, h.Bg
			if fg == "" {
				fg = normal.Fg
			}
			if bg == "" {
				bg = normal.Bg
			}
			h = Highlight{Fg: bg, Bg: fg}
		}
		g[name] = h
	}
	g["Normal"] = Highlight{Fg: normal.Fg, Bg: normal.Bg}
	return g
}

// attr reads "Group" (foreground) or "Group.bg".
func (g groups) attr(src string) string {
	if n := len(src) - 3; n > 0 && src[n:] == ".bg" {
		return g[src[:n]].Bg
	}
	return g[src].Fg
}

// fallback covers groups a scheme left unset, by stepping off the background.
func fallback(key string, g groups) string {
	bg := g.attr("Normal.bg")
	switch key {
	case "current_line_color", "line_length_guideline_color", "folded_code_region_color",
		"word_highlighted_color", "completion_selected_color", "completion_scroll_color",
		"completion_scroll_hovered_color", "selection_color", "search_result_color",
		"search_result_border_color":
		return step(bg, 0.08)
	}
	return g.attr("Normal")
}

// base is the interface base color: the cursor line, which a scheme sets one
// step off its background, or that step computed.
func base(g groups) string {
	bg := g.attr("Normal.bg")
	if c := g.attr("CursorLine.bg"); c != "" && c != bg {
		return c
	}
	return step(bg, 0.05)
}

// accent prefers the cursor line number, which schemes tend to give their
// signature color, then the most saturated syntax color.
func accent(g groups) string {
	if c := g.attr("CursorLineNr"); c != "" && saturation(c) >= 0.3 {
		return c
	}
	best, bestS := g.attr("Normal"), -1.0
	for _, s := range []string{"Function", "Keyword", "Statement", "Type", "String", "Constant"} {
		if c := g.attr(s); c != "" && saturation(c) > bestS {
			best, bestS = c, saturation(c)
		}
	}
	return best
}

func rgb(hex string) (r, g, b float64) {
	n, _ := strconv.ParseUint(hex, 16, 32)
	return float64(n>>16&0xff) / 255, float64(n>>8&0xff) / 255, float64(n&0xff) / 255
}

func luminance(hex string) float64 {
	r, g, b := rgb(hex)
	return 0.2126*r + 0.7152*g + 0.0722*b
}

// saturation is HSL saturation, 0 to 1.
func saturation(hex string) float64 {
	r, g, b := rgb(hex)
	hi, lo := math.Max(r, math.Max(g, b)), math.Min(r, math.Min(g, b))
	if hi == lo {
		return 0
	}
	l := (hi + lo) / 2
	return (hi - lo) / (1 - math.Abs(2*l-1))
}

// step moves a color toward white on a dark background, black on a light one.
func step(hex string, amount float64) string {
	r, g, b := rgb(hex)
	to := 1.0
	if luminance(hex) > 0.5 {
		to = 0
	}
	mix := func(c float64) int { return int(math.Round((c + (to-c)*amount) * 255)) }
	return fmt.Sprintf("%02x%02x%02x", mix(r), mix(g), mix(b))
}
