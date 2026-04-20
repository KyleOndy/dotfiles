package main

import (
	"fmt"
	"os"

	"github.com/kyleondy/dotfiles/forge/cmd"
)

var version = "dev"

func main() {
	if err := cmd.New(version).Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
