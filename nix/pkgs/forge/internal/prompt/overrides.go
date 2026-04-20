package prompt

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Overrides bundles prompt decorations loaded from a repo-keyed directory
// under FORGE_PROMPTS_ROOT. Zero value is a no-op Apply.
type Overrides struct {
	Prefix  string
	Suffix  string
	Sources []string // "<repo>/<file>" paths that contributed, in wrap order
}

// DetectRepo resolves a repo key from cwd. Prefers the basename of the
// git toplevel; falls back to filepath.Base(cwd). Returns "" when cwd is
// empty or resolves to a filesystem root.
func DetectRepo(cwd string) string {
	if cwd == "" {
		return ""
	}
	if top, err := gitToplevel(cwd); err == nil && top != "" {
		return filepath.Base(top)
	}
	base := filepath.Base(cwd)
	if base == "." || base == "/" || base == string(filepath.Separator) {
		return ""
	}
	return base
}

func gitToplevel(cwd string) (string, error) {
	cmd := exec.Command("git", "-C", cwd, "rev-parse", "--show-toplevel")
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return strings.TrimSpace(out.String()), nil
}

// LoadOverrides reads from <root>/<repo>/:
//
//	_common.prefix.md     (prepended to every phase)
//	<phase>.prefix.md     (prepended, after _common.prefix)
//	<phase>.suffix.md     (appended, before _common.suffix)
//	_common.suffix.md     (appended last)
//
// Missing files contribute nothing. Contents are TrimSpace'd.
func LoadOverrides(root, repo, phase string) Overrides {
	if root == "" || repo == "" || phase == "" {
		return Overrides{}
	}
	dir := filepath.Join(root, repo)
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}

	var ov Overrides
	var prefix, suffix []string

	if s := read("_common.prefix.md"); s != "" {
		prefix = append(prefix, s)
		ov.Sources = append(ov.Sources, repo+"/_common.prefix.md")
	}
	if s := read(phase + ".prefix.md"); s != "" {
		prefix = append(prefix, s)
		ov.Sources = append(ov.Sources, repo+"/"+phase+".prefix.md")
	}
	if s := read(phase + ".suffix.md"); s != "" {
		suffix = append(suffix, s)
		ov.Sources = append(ov.Sources, repo+"/"+phase+".suffix.md")
	}
	if s := read("_common.suffix.md"); s != "" {
		suffix = append(suffix, s)
		ov.Sources = append(ov.Sources, repo+"/_common.suffix.md")
	}
	ov.Prefix = strings.Join(prefix, "\n\n")
	ov.Suffix = strings.Join(suffix, "\n\n")
	return ov
}

// Apply wraps base with the prefix and suffix, joined by blank lines. When
// both prefix and suffix are empty, base is returned unchanged.
func (ov Overrides) Apply(base string) string {
	if ov.Prefix == "" && ov.Suffix == "" {
		return base
	}
	parts := make([]string, 0, 3)
	if ov.Prefix != "" {
		parts = append(parts, ov.Prefix)
	}
	parts = append(parts, strings.TrimSpace(base))
	if ov.Suffix != "" {
		parts = append(parts, ov.Suffix)
	}
	return strings.Join(parts, "\n\n")
}
