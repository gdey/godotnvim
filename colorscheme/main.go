// Command vim2godot converts a Vim or Neovim colorscheme into a Godot 4.5
// editor theme.
//
//	go run . https://vimcolorschemes.com/r/aejkatappaja/cendre
//
// It loads each scheme in headless Neovim, reads the highlight groups it
// sets, and maps them onto Godot's script-editor colors and interface
// base/accent colors. See README.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

// version is set by the release build (-ldflags "-X main.version=...").
var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "vim2godot:", err)
		os.Exit(1)
	}
}

func run() error {
	fs := flag.NewFlagSet("vim2godot", flag.ExitOnError)
	out := fs.String("out", "themes", "directory to write the themes to")
	only := fs.String("scheme", "", "comma-separated colorschemes to convert (default: all in colors/)")
	bgs := fs.String("background", "dark,light", "'background' values to try; a scheme that ignores it is written once")
	with := fs.String("with", "", "comma-separated repositories the scheme needs on 'runtimepath', such as rktjmp/lush.nvim")
	nvim := fs.String("nvim", envOr("NVIM", "nvim"), "path to nvim (or set $NVIM)")
	install := fs.Bool("install", false, "also copy the .tet files into Godot's text_editor_themes folder")
	timeout := fs.Duration("timeout", 20*time.Second, "time limit for loading each scheme")
	showVersion := fs.Bool("version", false, "print the version and exit")
	fs.Usage = func() {
		fmt.Fprintln(fs.Output(), "usage: vim2godot [flags] <repository>")
		fmt.Fprintln(fs.Output(), "\nrepository: a vimcolorschemes.com page, GitHub URL, owner/name, or local directory")
		fs.PrintDefaults()
	}
	fs.Parse(os.Args[1:])
	if *showVersion {
		fmt.Println("vim2godot", version)
		return nil
	}
	if fs.NArg() != 1 {
		fs.Usage()
		os.Exit(2)
	}
	source := fs.Arg(0)
	ctx := context.Background()

	dir, cleanup, err := fetch(ctx, source)
	if err != nil {
		return err
	}
	defer cleanup()
	ex := Extractor{Nvim: *nvim, RTP: []string{dir}, Timeout: *timeout}
	for _, dep := range split(*with) {
		d, c, err := fetch(ctx, dep)
		if err != nil {
			return err
		}
		defer c()
		ex.RTP = append(ex.RTP, d)
	}

	names := split(*only)
	if len(names) == 0 {
		if names, err = schemes(dir); err != nil {
			return err
		}
	}

	written := 0
	for _, name := range names {
		// One variant per 'background' the scheme ends up with. A scheme that
		// forces it can still differ slightly between runs (groups it leaves
		// to Neovim's defaults), so keep the run that asked for it.
		var variants []*Palette
		for _, bg := range split(*bgs) {
			p, err := ex.Extract(ctx, name, bg)
			if err != nil {
				fmt.Fprintln(os.Stderr, "skip:", err)
				break
			}
			if i := index(variants, p.Background); i < 0 {
				variants = append(variants, p)
			} else if p.Background == bg {
				variants[i] = p
			}
		}
		for _, p := range variants {
			tn := themeName(name, p, len(variants) > 1)
			t, err := Convert(tn, p)
			if err != nil {
				fmt.Fprintln(os.Stderr, "skip:", err)
				continue
			}
			d, err := t.Write(*out, source)
			if err != nil {
				return err
			}
			fmt.Println("wrote", d)
			written++
			if *install {
				p, err := t.Install(source)
				if err != nil {
					return err
				}
				fmt.Println("installed", p)
			}
		}
	}
	if written == 0 {
		return fmt.Errorf("no themes written")
	}
	return nil
}

// themeName names a variant, avoiding the names Godot reserves for its own
// themes (it refuses to load default.tet, custom.tet and godot 2.tet).
func themeName(scheme string, p *Palette, several bool) string {
	n := scheme
	if several {
		n += "-" + p.Background
	}
	switch strings.ToLower(n) {
	case "default", "custom", "godot 2":
		n = "vim-" + n
	}
	return n
}

func index(ps []*Palette, background string) int {
	for i, p := range ps {
		if p.Background == background {
			return i
		}
	}
	return -1
}

func split(s string) []string {
	var out []string
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
