package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestCloneURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://vimcolorschemes.com/r/aejkatappaja/cendre":      "https://github.com/aejkatappaja/cendre",
		"https://vimcolorschemes.com/r/aejkatappaja/cendre/dark": "https://github.com/aejkatappaja/cendre",
		"https://github.com/folke/tokyonight.nvim.git":           "https://github.com/folke/tokyonight.nvim",
		"https://github.com/folke/tokyonight.nvim/tree/main":     "https://github.com/folke/tokyonight.nvim",
		"morhetz/gruvbox":        "https://github.com/morhetz/gruvbox",
		"https://gitlab.com/a/b": "https://gitlab.com/a/b",
		"testdata":               "",
	} {
		got, err := cloneURL(in)
		if err != nil || got != want {
			t.Errorf("cloneURL(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := cloneURL("https://vimcolorschemes.com/top"); err == nil {
		t.Error("vimcolorschemes.com page without /r/owner/name: want an error")
	}
}

func TestSchemes(t *testing.T) {
	got, err := schemes("testdata")
	if err != nil || len(got) != 1 || got[0] != "fixture" {
		t.Fatalf("schemes(testdata) = %v, %v", got, err)
	}
}

func palette() *Palette {
	return &Palette{Background: "dark", Groups: map[string]Highlight{
		"Normal":          {Fg: "dddddd", Bg: "101010"},
		"Comment":         {Fg: "777777"},
		"String":          {Fg: "88cc66"},
		"@string":         {Fg: "88cc66"},
		"Function":        {Fg: "ffbb66"},
		"@function.call":  {Fg: "ffaa00"},
		"Keyword":         {Fg: "cc6666"},
		"CursorLine":      {Bg: "1c1c1c"},
		"CursorLineNr":    {Fg: "ff8844"},
		"Visual":          {Reverse: true},
		"Todo":            {Fg: "101010", Bg: "eeaa00"},
		"DiagnosticError": {Fg: "ff3366"},
	}}
}

func TestConvert(t *testing.T) {
	th, err := Convert("fixture", palette())
	if err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{
		"background_color":                   "101010ff",
		"text_color":                         "ddddddff",
		"function_color":                     "ffaa00ff", // treesitter group wins
		"gdscript/function_definition_color": "ffbb66ff",
		"keyword_color":                      "cc6666ff",
		"comment_color":                      "777777ff",
		"selection_color":                    "ddddddff", // reverse: Normal's foreground
		"current_line_color":                 "1c1c1cff",
		"search_result_color":                "23232340", // unset: a step off the background
		"comment_markers/warning_color":      "eeaa00ff", // Todo badge: its background
		"breakpoint_color":                   "ff3366ff",
		"safe_line_number_color":             "88cc6680",
		"text_selected_color":                "10101000",
	} {
		if got := th.Colors[k]; got != want {
			t.Errorf("%s = %s, want %s", k, got, want)
		}
	}
	for _, r := range rules {
		if _, ok := th.Colors[r.key]; !ok {
			t.Errorf("%s missing", r.key)
		}
	}
	if th.Base != "1c1c1c" || th.Accent != "ff8844" {
		t.Errorf("base, accent = %s, %s; want 1c1c1c, ff8844", th.Base, th.Accent)
	}
}

func TestConvertTransparent(t *testing.T) {
	p := palette()
	p.Groups["Normal"] = Highlight{Fg: "dddddd"}
	if _, err := Convert("clear", p); err == nil {
		t.Error("Normal without a background: want an error")
	}
}

func TestTET(t *testing.T) {
	th, _ := Convert("fixture", palette())
	tet := th.TET("testdata")
	if !strings.Contains(tet, "\n[color_theme]\n\n") || !strings.Contains(tet, "\nkeyword_color=\"cc6666ff\"\n") {
		t.Errorf("unexpected .tet:\n%s", tet)
	}
	if apply := th.Apply(); !strings.Contains(apply, `"text_editor/theme/color_theme": "fixture"`) {
		t.Errorf("apply script does not select the theme:\n%s", apply)
	}
}

func TestThemeName(t *testing.T) {
	light := &Palette{Background: "light"}
	if got := themeName("default", light, false); got != "vim-default" {
		t.Errorf("default -> %s", got)
	}
	if got := themeName("gruvbox", light, true); got != "gruvbox-light" {
		t.Errorf("gruvbox light -> %s", got)
	}
}

// TestExtract runs Neovim; it is skipped when nvim is not installed.
func TestExtract(t *testing.T) {
	nvim := envOr("NVIM", "nvim")
	if _, err := exec.LookPath(nvim); err != nil {
		t.Skip("nvim not found; set $NVIM")
	}
	dir, _ := os.Getwd()
	ex := Extractor{Nvim: nvim, RTP: []string{dir + "/testdata"}, Timeout: 20 * time.Second}
	p, err := ex.Extract(context.Background(), "fixture", "light")
	if err != nil {
		t.Fatal(err)
	}
	if p.Background != "dark" {
		t.Errorf("background = %s; the scheme sets dark", p.Background)
	}
	th, err := Convert("fixture", p)
	if err != nil {
		t.Fatal(err)
	}
	if got := th.Colors["keyword_color"]; got != "cc6666ff" {
		t.Errorf("keyword_color = %s; want cc6666ff (via @keyword -> Keyword)", got)
	}
	if got := th.Colors["selection_color"]; got != "ddddddff" {
		t.Errorf("selection_color = %s; want ddddddff (Visual is reverse)", got)
	}
	if _, err := ex.Extract(context.Background(), "nonexistent", "dark"); err == nil {
		t.Error("missing colorscheme: want an error")
	}
}
