package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// cloneURL turns what the user passed into a git URL. It accepts a
// vimcolorschemes.com page (https://vimcolorschemes.com/r/owner/name), a
// GitHub URL, "owner/name" or any other git URL. A local directory returns "".
func cloneURL(arg string) (string, error) {
	if fi, err := os.Stat(arg); err == nil && fi.IsDir() {
		return "", nil
	}
	if !strings.Contains(arg, "://") {
		if parts := strings.Split(arg, "/"); len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			return "https://github.com/" + arg, nil
		}
		if strings.HasPrefix(arg, "git@") {
			return arg, nil
		}
		return "", fmt.Errorf("%q is not a directory, owner/name, or URL", arg)
	}
	u, err := url.Parse(arg)
	if err != nil {
		return "", err
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	switch strings.TrimPrefix(u.Host, "www.") {
	case "vimcolorschemes.com":
		// /r/owner/name, sometimes followed by a tab such as /dark.
		if len(parts) < 3 || parts[0] != "r" {
			return "", fmt.Errorf("%s: expected https://vimcolorschemes.com/r/owner/name", arg)
		}
		return "https://github.com/" + parts[1] + "/" + parts[2], nil
	case "github.com":
		if len(parts) < 2 {
			return "", fmt.Errorf("%s: expected https://github.com/owner/name", arg)
		}
		return "https://github.com/" + parts[0] + "/" + strings.TrimSuffix(parts[1], ".git"), nil
	}
	return arg, nil
}

// fetch returns a local directory holding the repository, cloning it into a
// temporary directory when needed. cleanup removes that directory.
func fetch(ctx context.Context, arg string) (dir string, cleanup func(), err error) {
	u, err := cloneURL(arg)
	if err != nil {
		return "", nil, err
	}
	if u == "" {
		dir, err := filepath.Abs(arg)
		return dir, func() {}, err
	}
	tmp, err := os.MkdirTemp("", "vim2godot-repo-")
	if err != nil {
		return "", nil, err
	}
	cleanup = func() { os.RemoveAll(tmp) }
	cmd := exec.CommandContext(ctx, "git", "clone", "--quiet", "--depth", "1", u, tmp)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	if out, err := cmd.CombinedOutput(); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("git clone %s: %v: %s", u, err, strings.TrimSpace(string(out)))
	}
	return tmp, cleanup, nil
}

// schemes lists the colorschemes a repository ships: the files in colors/.
func schemes(dir string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(dir, "colors"))
	if err != nil {
		return nil, fmt.Errorf("%s has no colors/ directory, so no colorschemes", dir)
	}
	seen := map[string]bool{}
	var names []string
	for _, e := range entries {
		ext := filepath.Ext(e.Name())
		if e.IsDir() || (ext != ".vim" && ext != ".lua") {
			continue
		}
		n := strings.TrimSuffix(e.Name(), ext)
		if !seen[n] {
			seen[n] = true
			names = append(names, n)
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		return nil, fmt.Errorf("%s/colors has no .vim or .lua colorschemes", dir)
	}
	return names, nil
}
