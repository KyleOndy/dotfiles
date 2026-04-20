//go:build !windows

package flux

import (
	"os/exec"
	"syscall"
)

// detach puts the background child in its own process group so it outlives
// the completion process that spawned it.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}
