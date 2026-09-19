package main

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type Action string

const (
	ActNone        Action = ""
	ActQuit        Action = "quit"
	ActUp          Action = "up"
	ActDown        Action = "down"
	ActTop         Action = "top"
	ActBottom      Action = "bottom"
	ActHalfDown    Action = "half_page_down"
	ActHalfUp      Action = "half_page_up"
	ActPageDown    Action = "page_down"
	ActPageUp      Action = "page_up"
	ActNextSection Action = "next_section"
	ActPrevSection Action = "prev_section"
	ActPeekDown    Action = "peek_down"
	ActPeekUp      Action = "peek_up"
	ActActivate    Action = "activate"
	ActCollapse    Action = "collapse"
	ActFoldOpen    Action = "fold_open"
	ActFoldClose   Action = "fold_close"
	ActFoldToggle  Action = "fold_toggle"
	ActSnooze      Action = "snooze"
	ActWake        Action = "wake"
	ActTogglePin   Action = "toggle_pin"
	ActSettle      Action = "settle"
	ActAlias       Action = "alias"
	ActLinkPR      Action = "link_pr"
	ActOpenPR      Action = "open_pr"
	ActStop        Action = "stop"
	ActDelete      Action = "delete"
	ActRefresh     Action = "refresh"
	ActTogglePeek  Action = "toggle_peek"
	ActNewSession  Action = "new_session"
	ActFilter      Action = "filter"
	ActCommand     Action = "command"
	ActEscape      Action = "escape"
	ActShowHelp    Action = "help"
)

// Kept in step with Keymap::BINDINGS in the Ruby.
var bindings = map[string]Action{
	"j": ActDown, "down": ActDown,
	"k": ActUp, "up": ActUp,
	"G":      ActBottom,
	"ctrl+d": ActHalfDown, "ctrl+u": ActHalfUp,
	"ctrl+f": ActPageDown, "ctrl+b": ActPageUp,
	"ctrl+e": ActPeekDown, "ctrl+y": ActPeekUp,
	"J": ActPeekDown, "K": ActPeekUp,
	"enter": ActActivate, "l": ActActivate, "right": ActActivate,
	"h": ActCollapse, "left": ActCollapse,
	"s": ActSnooze, "u": ActWake, "a": ActAlias, "x": ActSettle, "X": ActStop,
	"ctrl+x": ActDelete,
	"o":      ActOpenPR, "P": ActLinkPR, "t": ActTogglePin,
	"R": ActRefresh, "p": ActTogglePeek, "n": ActNewSession,
	"tab": ActNextSection, "shift+tab": ActPrevSection,
	"/": ActFilter, ":": ActCommand, "esc": ActEscape,
	"q": ActQuit, "ctrl+c": ActQuit, "?": ActShowHelp,
}

var chords = map[string]map[string]Action{
	"g": {"g": ActTop},
	"z": {"o": ActFoldOpen, "c": ActFoldClose, "a": ActFoldToggle},
}

var commands = map[string]Action{
	"q": ActQuit, "quit": ActQuit, "q!": ActQuit, "wq": ActQuit,
	"peek": ActTogglePeek, "refresh": ActRefresh, "new": ActNewSession, "n": ActNewSession,
	"pr": ActOpenPR, "pin": ActTogglePin, "help": ActShowHelp,
}

const chordTimeout = time.Second

type Keymap struct {
	pending   string
	pendingAt time.Time
}

func (k *Keymap) Pending() string { return k.pending }

func (k *Keymap) Press(msg tea.KeyMsg) Action {
	name := msg.String()
	if k.pending != "" && time.Since(k.pendingAt) > chordTimeout {
		k.pending = ""
	}
	if k.pending != "" {
		table := chords[k.pending]
		k.pending = ""
		return table[name]
	}
	if _, ok := chords[name]; ok {
		k.pending = name
		k.pendingAt = time.Now()
		return ActNone
	}
	return bindings[name]
}

func CommandAction(line string) Action {
	return commands[strings.TrimSpace(line)]
}
