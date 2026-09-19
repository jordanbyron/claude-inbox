package main

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	root := os.Getenv("CLAUDE_INBOX_ROOT")
	if root == "" {
		exe, _ := os.Executable()
		root = filepath.Dir(filepath.Dir(exe))
	}
	backend := NewBackend(root, os.Args[1:])
	if err := backend.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "claude-inbox: cannot start backend:", err)
		os.Exit(1)
	}
	p := tea.NewProgram(NewModel(backend), tea.WithAltScreen(), tea.WithMouseCellMotion())
	_, err := p.Run()
	backend.Stop()
	if err != nil {
		fmt.Fprintln(os.Stderr, "claude-inbox:", err)
		os.Exit(1)
	}
}
