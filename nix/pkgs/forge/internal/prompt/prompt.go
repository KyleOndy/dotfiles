// Package prompt embeds and renders the agent-facing markdown templates.
//
// Templates live in ./templates and are embedded at build time. Rendering
// is plain `{{KEY}}` substring substitution — Go's text/template would
// collide with literal ${...} shell fragments and code-fence braces in
// the templates.
package prompt

import (
	"embed"
	"fmt"
	"strings"
)

//go:embed templates/*.md
var fs embed.FS

// Render reads templates/<name> and replaces every {{KEY}} with the
// corresponding value from vars. Unknown placeholders are left intact so
// missing inputs are visible to the caller (and the model).
func Render(name string, vars map[string]string) (string, error) {
	b, err := fs.ReadFile("templates/" + name)
	if err != nil {
		return "", fmt.Errorf("template %s: %w", name, err)
	}
	out := string(b)
	for k, v := range vars {
		out = strings.ReplaceAll(out, "{{"+k+"}}", v)
	}
	return out, nil
}

// Names lists the embedded template basenames (sans path).
func Names() []string {
	entries, _ := fs.ReadDir("templates")
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}
