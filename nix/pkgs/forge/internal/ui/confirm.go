package ui

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// Confirm prints a y/N prompt to stderr and reads stdin. Returns true only
// for an explicit "y" or "Y". Empty input means no.
func Confirm(prompt string) bool {
	fmt.Fprintf(os.Stderr, "%s [y/N] ", prompt)
	r := bufio.NewReader(os.Stdin)
	line, err := r.ReadString('\n')
	if err != nil {
		return false
	}
	line = strings.TrimSpace(line)
	return line == "y" || line == "Y"
}

// ConfirmOrDie either returns nil (yes), an error (no), or returns nil
// without prompting when autoApprove is true.
func ConfirmOrDie(prompt string, autoApprove bool) error {
	if autoApprove {
		L().Info("auto-approve set, skipping confirm: %s", prompt)
		return nil
	}
	if Confirm(prompt) {
		return nil
	}
	return fmt.Errorf("user declined: %s", prompt)
}
