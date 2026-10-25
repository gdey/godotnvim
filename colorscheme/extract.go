package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

//go:embed extract.lua
var extractLua []byte

// Highlight is one resolved highlight group. Colors are "rrggbb", empty when
// the group leaves them unset.
type Highlight struct {
	Fg      string `json:"fg"`
	Bg      string `json:"bg"`
	Reverse bool   `json:"reverse"`
}

// Palette is a colorscheme as Neovim resolved it.
type Palette struct {
	Background string               `json:"background"` // "dark" or "light"
	Groups     map[string]Highlight `json:"groups"`
}

// Extractor loads colorschemes in headless Neovim.
type Extractor struct {
	Nvim    string        // path to nvim
	RTP     []string      // prepended to 'runtimepath': the scheme and its dependencies
	Timeout time.Duration // per scheme
}

// Extract loads scheme with 'background' set to bg first. A scheme may set
// 'background' itself, so the result says which one it ended up with.
//
// This runs the colorscheme's code. Only extract schemes you would load in
// your own Neovim.
func (e Extractor) Extract(ctx context.Context, scheme, bg string) (*Palette, error) {
	dir, err := os.MkdirTemp("", "vim2godot-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	script := filepath.Join(dir, "extract.lua")
	if err := os.WriteFile(script, extractLua, 0o644); err != nil {
		return nil, err
	}
	out := filepath.Join(dir, "palette.json")

	ctx, cancel := context.WithTimeout(ctx, e.Timeout)
	defer cancel()
	args := []string{"--headless", "--clean", "-i", "NONE"}
	for _, p := range e.RTP {
		args = append(args, "--cmd", "set rtp^="+escapeOpt(p))
	}
	args = append(args,
		"--cmd", "set termguicolors background="+bg,
		"-c", "luafile "+escapeOpt(script))
	cmd := exec.CommandContext(ctx, e.Nvim, args...)
	cmd.Env = append(os.Environ(), "VIM2GODOT_SCHEME="+scheme, "VIM2GODOT_OUT="+out)
	cmd.Stdin = nil
	msg, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("colorscheme %s: timed out after %s", scheme, e.Timeout)
	}
	if err != nil {
		return nil, fmt.Errorf("colorscheme %s: %v: %s", scheme, err, strings.TrimSpace(string(msg)))
	}
	data, err := os.ReadFile(out)
	if err != nil {
		return nil, fmt.Errorf("colorscheme %s: no output: %s", scheme, strings.TrimSpace(string(msg)))
	}
	var p Palette
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("colorscheme %s: %w", scheme, err)
	}
	return &p, nil
}

// escapeOpt escapes a path for an Ex command argument.
func escapeOpt(s string) string {
	r := strings.NewReplacer(`\`, `\\`, ` `, `\ `, `,`, `\,`, `|`, `\|`)
	return r.Replace(s)
}
