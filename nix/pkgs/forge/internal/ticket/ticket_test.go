package ticket

import "testing"

func TestValidate(t *testing.T) {
	cases := []struct {
		id      string
		wantErr bool
	}{
		{"", true},
		{"PROJ-123", false},
		{"ENG-1", false},
		{"FOOBAR-9999", false},
		{"proj-123", true},
		{"PROJ-", true},
		{"PROJ-abc", true},
		{"ADHOC-test", false},
		{"ADHOC-config-loader-port", false},
		{"ADHOC_underscore-ok", false},
		{"ADHOC-", true},
		{"OR-research", false},
		{"ONDY-personal", false},
		{"random", true},
	}
	for _, c := range cases {
		err := Validate(c.id)
		if (err != nil) != c.wantErr {
			t.Errorf("Validate(%q): err=%v wantErr=%v", c.id, err, c.wantErr)
		}
	}
}

func TestIsLinear(t *testing.T) {
	if !IsLinear("PROJ-1019") {
		t.Error("PROJ-1019 should be linear")
	}
	if IsLinear("ADHOC-test") {
		t.Error("ADHOC-test should not be linear")
	}
}

func TestPaths(t *testing.T) {
	got := Root("/r", "ENG-1")
	if got != "/r/ENG-1" {
		t.Errorf("Root: got %q", got)
	}
	if TaskDir("/r", "ENG-1", "T03", "wire-up") != "/r/ENG-1/tasks/T03-wire-up" {
		t.Errorf("TaskDir wrong")
	}
}
