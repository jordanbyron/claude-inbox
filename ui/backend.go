package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"

	tea "github.com/charmbracelet/bubbletea"
)

// Backend is the Ruby side of the pipe: bin/claude-inbox-server as a child,
// one JSON object per line each way. Events arrive as tea.Msgs; commands
// are plain maps. Attach runs the same script with the tty, so it is the
// one command that goes through tea.ExecProcess rather than the pipe.
type Backend struct {
	root    string
	args    []string
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	scanner *bufio.Scanner
	mu      sync.Mutex
}

type Row struct {
	Key           string `json:"key"`
	ID            string `json:"id"`
	SessionID     string `json:"session_id"`
	Selectable    bool   `json:"selectable"`
	Label         string `json:"label"`
	Aliased       bool   `json:"aliased"`
	Cwd           string `json:"cwd"`
	Project       string `json:"project"`
	Pid           int    `json:"pid"`
	State         string `json:"state"`
	Status        string `json:"status"`
	WaitingFor    string `json:"waiting_for"`
	Interactive   bool   `json:"interactive"`
	Remote        bool   `json:"remote"`
	Terminal      bool   `json:"terminal"`
	Actionable    bool   `json:"actionable"`
	Alive         bool   `json:"alive"`
	Finished      bool   `json:"finished"`
	WaitingOnWork bool   `json:"waiting_on_work"`
	InFlight      string `json:"in_flight"`
	Color         string `json:"color"`
	StartedAt     int64  `json:"started_at"`
	StateSince    int64  `json:"state_since"`
	WakeAt        int64  `json:"wake_at"`
	Parked        bool   `json:"parked"`
	Pinned        bool   `json:"pinned"`
	PRs           []PR   `json:"prs"`
}

type PR struct {
	Short string `json:"short"`
	URL   string `json:"url"`
	State string `json:"state"`
}

func (r Row) PR() *PR {
	if len(r.PRs) == 0 {
		return nil
	}
	return &r.PRs[0]
}

type Section struct {
	Name string `json:"name"`
	Rows []Row  `json:"rows"`
}

type SectionsMsg struct {
	Now      int64     `json:"now"`
	Polled   bool      `json:"polled"`
	Sections []Section `json:"sections"`
}

type PolledMsg struct{ At int64 }
type ErrorMsg struct{ Message string }
type NoticeMsg struct{ Message string }
type PeekMsg struct {
	ID    string
	Lines []string
}
type SpawnedMsg struct {
	ID     string
	Attach bool
}
type DefaultsMsg struct {
	Cwd            string
	Model          string
	Effort         string
	PermissionMode string
}
type Command struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}
type CommandsMsg struct {
	Cwd      string
	Commands []Command
}
type BackendGoneMsg struct{ Err error }

func NewBackend(root string, args []string) *Backend {
	return &Backend{root: root, args: args}
}

func (b *Backend) Start() error {
	b.cmd = exec.Command(b.root+"/bin/claude-inbox-server", b.args...)
	b.cmd.Stderr = os.Stderr
	stdin, err := b.cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := b.cmd.StdoutPipe()
	if err != nil {
		return err
	}
	b.stdin = stdin
	b.scanner = bufio.NewScanner(stdout)
	b.scanner.Buffer(make([]byte, 1<<20), 16<<20)
	return b.cmd.Start()
}

func (b *Backend) Stop() {
	b.Send(map[string]any{"cmd": "quit"})
	b.stdin.Close()
	if b.cmd != nil && b.cmd.Process != nil {
		b.cmd.Wait()
	}
}

func (b *Backend) Send(cmd map[string]any) {
	line, err := json.Marshal(cmd)
	if err != nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	fmt.Fprintf(b.stdin, "%s\n", line)
}

// AttachCmd hands the tty to `claude attach` through the Ruby client, whose
// watchdog is what keeps ← from landing in the native agents view.
func (b *Backend) AttachCmd(id string) *exec.Cmd {
	args := append([]string{"attach", id}, b.args...)
	return exec.Command(b.root+"/bin/claude-inbox-server", args...)
}

func (b *Backend) Next() tea.Msg {
	if !b.scanner.Scan() {
		return BackendGoneMsg{Err: b.scanner.Err()}
	}
	return decode(b.scanner.Bytes())
}

func decode(line []byte) tea.Msg {
	var head struct {
		Event string `json:"event"`
	}
	if err := json.Unmarshal(line, &head); err != nil {
		return ErrorMsg{Message: "bad event: " + err.Error()}
	}
	switch head.Event {
	case "sections":
		var m SectionsMsg
		json.Unmarshal(line, &m)
		return m
	case "polled":
		var m struct {
			At int64 `json:"at"`
		}
		json.Unmarshal(line, &m)
		return PolledMsg{At: m.At}
	case "error":
		var m struct {
			Message string `json:"message"`
		}
		json.Unmarshal(line, &m)
		return ErrorMsg{Message: m.Message}
	case "notice":
		var m struct {
			Message string `json:"message"`
		}
		json.Unmarshal(line, &m)
		return NoticeMsg{Message: m.Message}
	case "peek":
		var m struct {
			ID    string   `json:"id"`
			Lines []string `json:"lines"`
		}
		json.Unmarshal(line, &m)
		return PeekMsg{ID: m.ID, Lines: m.Lines}
	case "spawned":
		var m struct {
			ID     string `json:"id"`
			Attach bool   `json:"attach"`
		}
		json.Unmarshal(line, &m)
		return SpawnedMsg{ID: m.ID, Attach: m.Attach}
	case "defaults":
		var m struct {
			Cwd            string `json:"cwd"`
			Model          string `json:"model"`
			Effort         string `json:"effort"`
			PermissionMode string `json:"permission_mode"`
		}
		json.Unmarshal(line, &m)
		return DefaultsMsg{Cwd: m.Cwd, Model: m.Model, Effort: m.Effort, PermissionMode: m.PermissionMode}
	case "commands":
		var m struct {
			Cwd      string    `json:"cwd"`
			Commands []Command `json:"commands"`
		}
		json.Unmarshal(line, &m)
		return CommandsMsg{Cwd: m.Cwd, Commands: m.Commands}
	}
	return ErrorMsg{Message: "unknown event " + head.Event}
}
