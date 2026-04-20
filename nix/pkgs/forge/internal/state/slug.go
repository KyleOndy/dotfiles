package state

import (
	"regexp"
	"strings"
	"unicode"
)

const slugMaxLen = 40

var nonSlugRE = regexp.MustCompile(`[^a-z0-9]+`)

// Slugify lowercases, hyphenates, strips punctuation, caps length at 40.
func Slugify(s string) string {
	var b strings.Builder
	for _, r := range s {
		b.WriteRune(unicode.ToLower(r))
	}
	out := nonSlugRE.ReplaceAllString(b.String(), "-")
	out = strings.Trim(out, "-")
	if len(out) > slugMaxLen {
		out = out[:slugMaxLen]
	}
	return strings.Trim(out, "-")
}
