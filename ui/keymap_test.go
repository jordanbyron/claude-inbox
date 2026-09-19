package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func key(s string) tea.KeyMsg {
	if len(s) == 1 {
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	}
	switch s {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "ctrl+d":
		return tea.KeyMsg{Type: tea.KeyCtrlD}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func TestPlainBindings(t *testing.T) {
	var km Keymap
	if km.Press(key("j")) != ActDown || km.Press(key("enter")) != ActActivate || km.Press(key("ctrl+d")) != ActHalfDown {
		t.Fatal("plain bindings")
	}
}

func TestChordCompletes(t *testing.T) {
	var km Keymap
	if km.Press(key("g")) != ActNone {
		t.Fatal("first g should be pending")
	}
	if km.Pending() != "g" {
		t.Fatal("pending not recorded")
	}
	if km.Press(key("g")) != ActTop {
		t.Fatal("gg should be top")
	}
	km.Press(key("z"))
	if km.Press(key("a")) != ActFoldToggle {
		t.Fatal("za should toggle the fold")
	}
}

func TestUnknownSecondKeyDropsTheChord(t *testing.T) {
	var km Keymap
	km.Press(key("g"))
	if km.Press(key("x")) != ActNone || km.Pending() != "" {
		t.Fatal("gx should do nothing and clear the chord")
	}
	if km.Press(key("x")) != ActSettle {
		t.Fatal("x afterwards should be settle again")
	}
}

func TestCommandLine(t *testing.T) {
	if CommandAction(" q ") != ActQuit || CommandAction("peek") != ActTogglePeek || CommandAction("dance") != ActNone {
		t.Fatal("command table")
	}
}
