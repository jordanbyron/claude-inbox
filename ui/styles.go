package main

import "github.com/charmbracelet/lipgloss"

var (
	cyan    = lipgloss.Color("6")
	red     = lipgloss.Color("1")
	yellow  = lipgloss.Color("3")
	green   = lipgloss.Color("2")
	magenta = lipgloss.Color("5")
	blue    = lipgloss.Color("4")

	brandStyle  = lipgloss.NewStyle().Foreground(cyan).Bold(true)
	dimStyle    = lipgloss.NewStyle().Faint(true)
	keyStyle    = lipgloss.NewStyle().Foreground(cyan).Bold(true)
	titleStyle  = lipgloss.NewStyle().Bold(true)
	cursorStyle = lipgloss.NewStyle().Reverse(true)
	boxStyle    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cyan).Padding(0, 1)
	peekBar     = lipgloss.NewStyle().Reverse(true)
	selectedBg  = lipgloss.NewStyle().Background(lipgloss.Color("236"))

	sectionColors = map[string]lipgloss.Color{
		"pinned": cyan, "needs_you": red, "active": yellow, "snoozed": magenta, "settled": lipgloss.Color("8"),
	}
)

// The mapping is Claude Code's own tmux one: six ansi names, orange and pink by index.
func paletteColor(name string) (lipgloss.Color, bool) {
	switch name {
	case "red":
		return red, true
	case "green":
		return green, true
	case "yellow":
		return yellow, true
	case "blue":
		return blue, true
	case "purple":
		return magenta, true
	case "cyan":
		return cyan, true
	case "orange":
		return lipgloss.Color("208"), true
	case "pink":
		return lipgloss.Color("205"), true
	}
	return "", false
}

func colored(c lipgloss.Color) lipgloss.Style { return lipgloss.NewStyle().Foreground(c) }
