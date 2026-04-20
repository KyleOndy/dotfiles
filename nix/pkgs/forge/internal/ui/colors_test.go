package ui

import "testing"

func TestColorEmptyWhenNoColorSet(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	resetForTest()
	if got := Color("red"); got != "" {
		t.Fatalf("Color(red) = %q; want empty when NO_COLOR is set", got)
	}
}

func TestColorEmptyForUnknownName(t *testing.T) {
	t.Setenv("NO_COLOR", "")
	resetForTest()
	useColor = true
	if got := Color("magenta"); got != "" {
		t.Fatalf("Color(magenta) = %q; want empty for unknown color", got)
	}
}
