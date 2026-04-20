//go:build windows

package flux

import "os/exec"

// Windows isn't a supported forge target (see default.nix meta.platforms),
// but we keep a stub so the package still builds under `GOOS=windows go vet`.
func detach(_ *exec.Cmd) {}
