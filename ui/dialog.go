package main

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type Dialog interface {
	Press(tea.KeyMsg) string
	View(width int) string
}

type SnoozeChoice struct {
	Key, Label, Choice string
}

var snoozeMenu = []SnoozeChoice{
	{"1", "15 minutes", "m15"},
	{"2", "1 hour", "h1"},
	{"3", "tomorrow 9am", "tomorrow_9am"},
	{"4", "until I wake it", "until_woken"},
}

type SnoozeDialog struct {
	ID     string
	Choice string
}

func (d *SnoozeDialog) Press(msg tea.KeyMsg) string {
	k := msg.String()
	if k == "esc" || k == "q" {
		return "cancel"
	}
	for _, c := range snoozeMenu {
		if c.Key == k {
			d.Choice = c.Choice
			return "snooze"
		}
	}
	return ""
}

func (d *SnoozeDialog) View(width int) string {
	var b strings.Builder
	for _, c := range snoozeMenu {
		b.WriteString(keyStyle.Render(c.Key) + "  " + c.Label + "\n")
	}
	b.WriteString("\n" + keyStyle.Render("esc") + "  cancel")
	return box("Snooze", b.String(), width)
}

type ConfirmDialog struct {
	Kind string
	ID   string
}

func (d *ConfirmDialog) Press(msg tea.KeyMsg) string {
	switch msg.String() {
	case "y":
		return "confirm"
	case "esc", "n", "q":
		return "cancel"
	}
	return ""
}

func (d *ConfirmDialog) View(width int) string {
	if d.Kind == "stop" {
		body := "Stop session " + d.ID + "?\n\n" + keyStyle.Render("y") + "  stop it\n" + keyStyle.Render("esc") + "  cancel"
		return box("Stop", body, width)
	}
	body := "Delete session " + d.ID + "?\n" + dimStyle.Render("Its worktree and conversation\ngo with it.") +
		"\n\n" + keyStyle.Render("y") + "  delete it\n" + keyStyle.Render("esc") + "  keep it"
	return box("Delete", body, width)
}

type PromptDialog struct {
	Kind  string
	ID    string
	Value string
}

func (d *PromptDialog) Press(msg tea.KeyMsg) string {
	switch msg.String() {
	case "esc":
		return "cancel"
	case "enter":
		return "save"
	case "backspace", "ctrl+h":
		if d.Value != "" {
			r := []rune(d.Value)
			d.Value = string(r[:len(r)-1])
		}
	case "ctrl+u":
		d.Value = ""
	default:
		if msg.Type == tea.KeyRunes && !msg.Alt {
			d.Value += string(msg.Runes)
		}
	}
	return ""
}

func (d *PromptDialog) View(width int) string {
	title, question := "Alias", "New alias:"
	if d.Kind == "pr" {
		title, question = "Pull request", "Pull request URL (empty clears):"
	}
	body := question + "\n\n> " + d.Value + cursorStyle.Render(" ") + "\n\n" +
		keyStyle.Render("⏎") + " save · " + keyStyle.Render("esc") + " cancel"
	return box(title, body, width)
}

type HelpDialog struct{}

func (d *HelpDialog) Press(msg tea.KeyMsg) string {
	switch msg.String() {
	case "esc", "q", "?", "enter":
		return "cancel"
	}
	return ""
}

var helpRows = [][2]string{
	{"j k ↑ ↓", "move"}, {"gg G", "first / last"}, {"^d ^u", "half page"}, {"⇥ ⇧⇥", "next / previous section"},
	{"⏎ l", "attach, or expand a fold"}, {"h", "close peek, else fold"}, {"za zo zc", "toggle / open / close fold"},
	{"p", "peek pane"}, {"J K", "scroll the peek"}, {"n", "new session"}, {"t", "pin"}, {"s", "snooze"}, {"u", "wake / bring back"},
	{"x", "settle by hand"}, {"a", "alias"}, {"P", "link a pull request"}, {"o", "open the pull request"},
	{"X", "stop (asks)"}, {"^x", "delete (asks)"}, {"R", "poll now"}, {"/", "filter"}, {":", "command line"}, {"q", "quit"},
}

func (d *HelpDialog) View(width int) string {
	var b strings.Builder
	for _, r := range helpRows {
		b.WriteString(lipgloss.NewStyle().Width(10).Render(keyStyle.Render(r[0])) + " " + r[1] + "\n")
	}
	return box("Keys", strings.TrimRight(b.String(), "\n"), width)
}

func box(title, body string, width int) string {
	w := min(width-4, 48)
	return boxStyle.Width(w).Render(titleStyle.Render(" "+title+" ") + "\n\n" + body)
}
