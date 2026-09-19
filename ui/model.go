package main

import (
	"os/exec"
	"runtime"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type tickMsg time.Time
type attachDoneMsg struct{ err error }

const noticeFor = 4 * time.Second

type Model struct {
	backend  *Backend
	sections Sections
	polled   bool
	lastPoll time.Time
	bootedAt time.Time
	errText  string
	notice   string
	noticeTo time.Time

	width, height int
	tick          int
	top           int
	lineKeys      []string
	listWidth     int

	selected      string
	pendingSelect string
	expanded      map[string]bool
	keymap        Keymap

	filter        string
	filterEditing bool
	command       *string

	peekOpen   bool
	peekOffset int
	peekLines  map[string][]string

	dialog Dialog
	form   *Form
}

func NewModel(b *Backend) Model {
	return Model{
		backend:   b,
		bootedAt:  time.Now(),
		expanded:  map[string]bool{},
		peekLines: map[string][]string{},
		width:     100,
		height:    30,
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(m.backend.Next, tickEvery())
}

func tickEvery() tea.Cmd {
	return tea.Tick(250*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) send(cmd map[string]any) { m.backend.Send(cmd) }

func (m Model) sendFor(name string, extra ...any) {
	cmd := map[string]any{"cmd": name, "id": m.selected}
	for i := 0; i+1 < len(extra); i += 2 {
		cmd[extra[i].(string)] = extra[i+1]
	}
	m.backend.Send(cmd)
}

func (m *Model) setNotice(text string) {
	m.notice = text
	m.noticeTo = time.Now().Add(noticeFor)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = max(msg.Width, 40), max(msg.Height, 8)
		if m.form != nil {
			m.form.Resize(m.width, m.height-2)
		}
		return m, nil
	case tickMsg:
		m.tick++
		return m, tickEvery()
	case SectionsMsg:
		m.sections = Sections{list: msg.Sections}
		m.polled = msg.Polled
		m.errText = ""
		m.ensureSelection()
		return m, m.backend.Next
	case PolledMsg:
		m.lastPoll = time.Unix(msg.At, 0)
		return m, m.backend.Next
	case ErrorMsg:
		m.errText = msg.Message
		return m, m.backend.Next
	case NoticeMsg:
		m.setNotice(msg.Message)
		return m, m.backend.Next
	case PeekMsg:
		m.peekLines[msg.ID] = msg.Lines
		return m, m.backend.Next
	case SpawnedMsg:
		m.setNotice("started " + msg.ID)
		m.pendingSelect = msg.ID
		if msg.Attach {
			return m, tea.Batch(m.backend.Next, m.attach(msg.ID))
		}
		return m, m.backend.Next
	case DefaultsMsg, CommandsMsg:
		if m.form != nil {
			m.form.Receive(msg)
		}
		return m, m.backend.Next
	case BackendGoneMsg:
		m.errText = "backend exited"
		return m, tea.Quit
	case attachDoneMsg:
		m.send(map[string]any{"cmd": "resume"})
		return m, nil
	case tea.MouseMsg:
		return m.handleMouse(msg)
	case tea.KeyMsg:
		return m.handleKeys(msg)
	}
	return m, nil
}

// Runes that arrive in one read come as one KeyMsg, so a quick "gg" or
// ":q" would otherwise be a single unknown key. A paste is left whole.
func (m Model) handleKeys(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if msg.Type != tea.KeyRunes || len(msg.Runes) <= 1 || msg.Paste {
		return m.handleKey(msg)
	}
	var model tea.Model = m
	var cmds []tea.Cmd
	for _, r := range msg.Runes {
		var cmd tea.Cmd
		model, cmd = model.(Model).handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}, Alt: msg.Alt})
		cmds = append(cmds, cmd)
	}
	return model, tea.Batch(cmds...)
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.form != nil {
		return m.handleFormKey(msg)
	}
	if m.dialog != nil {
		return m.handleDialogKey(msg)
	}
	if m.filterEditing || m.command != nil {
		return m.handleLineKey(msg)
	}
	return m.perform(m.keymap.Press(msg))
}

func (m Model) handleMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if m.form != nil || m.dialog != nil || m.filterEditing || m.command != nil {
		return m, nil
	}
	switch msg.Button {
	case tea.MouseButtonWheelUp:
		return m.perform(ActUp)
	case tea.MouseButtonWheelDown:
		return m.perform(ActDown)
	case tea.MouseButtonLeft:
		if msg.Action != tea.MouseActionPress || msg.X >= m.listWidth {
			return m, nil
		}
		if key := m.keyAtLine(msg.Y); key != "" {
			m.selectKey(key)
			return m.activate()
		}
	}
	return m, nil
}

func (m Model) keyAtLine(y int) string {
	if y < 0 || y >= len(m.lineKeys) {
		return ""
	}
	if k := m.lineKeys[y]; k != "" {
		return k
	}
	if y > 0 {
		return m.lineKeys[y-1]
	}
	return ""
}

func (m Model) filtered() Sections { return m.sections.Matching(m.filter) }

func (m *Model) ensureSelection() {
	keys := m.filtered().SelectableKeys(m.expanded)
	if m.pendingSelect != "" && contains(keys, m.pendingSelect) {
		m.selectKey(m.pendingSelect)
		m.pendingSelect = ""
		return
	}
	if contains(keys, m.selected) {
		return
	}
	if len(keys) > 0 {
		m.selectKey(keys[0])
	} else {
		m.selected = ""
	}
}

func (m *Model) selectKey(key string) {
	if key == m.selected {
		return
	}
	m.selected = key
	m.peekOffset = 0
	m.wantPeek()
}

func (m *Model) wantPeek() {
	if r := m.selectedRow(); r != nil && r.Actionable {
		m.sendFor("peek")
	}
}

func (m Model) selectedRow() *Row { return m.sections.Row(m.selected) }

func (m *Model) requireActionable() bool {
	r := m.selectedRow()
	if r != nil && r.Actionable {
		return true
	}
	if r != nil && r.Interactive {
		if r.Remote {
			m.setNotice("that's a remote session — open it at claude.ai/code")
		} else {
			m.setNotice("that's your own terminal — switch to that window")
		}
	}
	return false
}

func (m *Model) requireStorable() bool {
	r := m.selectedRow()
	if r == nil {
		return false
	}
	if r.Terminal {
		m.setNotice("you're in that terminal right now — nothing to snooze")
		return false
	}
	return true
}

func (m Model) page() int { return max(m.height-2, 1) }

func (m Model) perform(a Action) (tea.Model, tea.Cmd) {
	switch a {
	case ActQuit:
		return m, tea.Quit
	case ActUp:
		m.move(-1)
	case ActDown:
		m.move(1)
	case ActTop:
		m.move(-1_000_000)
	case ActBottom:
		m.move(1_000_000)
	case ActHalfDown:
		m.move(m.page() / 2)
	case ActHalfUp:
		m.move(-(m.page() / 2))
	case ActPageDown:
		m.move(m.page())
	case ActPageUp:
		m.move(-m.page())
	case ActNextSection:
		m.jumpSection(1)
	case ActPrevSection:
		m.jumpSection(-1)
	case ActPeekDown:
		m.peekOffset = max(m.peekOffset-1, 0)
	case ActPeekUp:
		m.peekOffset++
	case ActActivate:
		return m.activate()
	case ActCollapse:
		if m.peekOpen {
			m.peekOpen = false
		} else if name := m.currentFoldSection(); name != "" && m.expanded[name] {
			m.expanded[name] = false
		}
	case ActFoldOpen:
		m.setExpanded(true)
	case ActFoldClose:
		m.setExpanded(false)
	case ActFoldToggle:
		m.setExpanded(!m.expanded[m.currentFoldSection()])
	case ActSnooze:
		if m.requireStorable() {
			m.dialog = &SnoozeDialog{ID: m.selected}
		}
	case ActWake:
		if m.requireStorable() {
			m.sendFor("wake")
		}
	case ActTogglePin:
		if m.requireStorable() {
			m.sendFor("toggle_pin")
		}
	case ActSettle:
		if m.requireStorable() {
			m.sendFor("settle")
			m.setNotice("settled — u brings it back")
		}
	case ActAlias:
		if m.requireStorable() {
			value := ""
			if r := m.selectedRow(); r != nil && r.Aliased {
				value = r.Label
			}
			m.dialog = &PromptDialog{Kind: "alias", ID: m.selected, Value: value}
		}
	case ActLinkPR:
		if m.requireStorable() {
			value := ""
			if pr := m.selectedRow().PR(); pr != nil {
				value = pr.URL
			}
			m.dialog = &PromptDialog{Kind: "pr", ID: m.selected, Value: value}
		}
	case ActOpenPR:
		return m, m.openPR()
	case ActStop:
		if m.requireActionable() {
			m.dialog = &ConfirmDialog{Kind: "stop", ID: m.selected}
		}
	case ActDelete:
		if m.requireActionable() {
			m.dialog = &ConfirmDialog{Kind: "delete", ID: m.selected}
		}
	case ActRefresh:
		m.send(map[string]any{"cmd": "refresh"})
	case ActTogglePeek:
		m.peekOpen = !m.peekOpen
		if m.peekOpen {
			m.wantPeek()
		}
	case ActNewSession:
		return m.openForm()
	case ActFilter:
		m.filterEditing = true
	case ActCommand:
		s := ""
		m.command = &s
	case ActEscape:
		m.filter = ""
		m.filterEditing = false
		m.command = nil
	case ActShowHelp:
		m.dialog = &HelpDialog{}
	}
	return m, nil
}

func (m *Model) move(delta int) {
	keys := m.filtered().SelectableKeys(m.expanded)
	if len(keys) == 0 {
		return
	}
	idx := index(keys, m.selected)
	if idx < 0 {
		idx = 0
	}
	m.selectKey(keys[clamp(idx+delta, 0, len(keys)-1)])
}

func (m *Model) jumpSection(dir int) {
	sections := m.filtered()
	heads := sections.Heads(m.expanded)
	if len(heads) == 0 {
		return
	}
	current := sections.SectionOf(m.selected)
	idx := -1
	for i, h := range heads {
		if h[0] == current {
			idx = i
		}
	}
	n := len(heads)
	m.selectKey(heads[((idx+dir)%n+n)%n][1])
}

func (m Model) currentFoldSection() string {
	name := m.filtered().SectionOf(m.selected)
	if foldable(name) {
		return name
	}
	return ""
}

func (m *Model) setExpanded(v bool) {
	if name := m.currentFoldSection(); name != "" {
		m.expanded[name] = v
	}
}

func (m Model) activate() (tea.Model, tea.Cmd) {
	if foldable(m.selected) {
		m.expanded[m.selected] = true
		return m, nil
	}
	if m.requireActionable() {
		return m, m.attach(m.selected)
	}
	return m, nil
}

// The poller is paused rather than stopped so nothing forks `claude` while
// the attached session holds the terminal.
func (m Model) attach(id string) tea.Cmd {
	m.send(map[string]any{"cmd": "acknowledge", "id": id})
	m.send(map[string]any{"cmd": "pause"})
	return tea.ExecProcess(m.backend.AttachCmd(id), func(err error) tea.Msg { return attachDoneMsg{err} })
}

func (m *Model) openPR() tea.Cmd {
	r := m.selectedRow()
	if r == nil || r.PR() == nil {
		m.setNotice("no pull request linked — P sets one")
		return nil
	}
	opener := "xdg-open"
	if runtime.GOOS == "darwin" {
		opener = "open"
	}
	m.setNotice("opening " + r.PR().Short)
	url := r.PR().URL
	return func() tea.Msg { exec.Command(opener, url).Run(); return nil }
}

func (m Model) handleDialogKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	d := m.dialog
	switch d.Press(msg) {
	case "cancel":
		m.dialog = nil
	case "snooze":
		m.sendFor("snooze", "choice", d.(*SnoozeDialog).Choice)
		m.dialog = nil
	case "confirm":
		c := d.(*ConfirmDialog)
		m.dialog = nil
		if c.Kind == "stop" {
			m.send(map[string]any{"cmd": "stop", "id": c.ID})
		} else {
			m.setNotice("deleting " + c.ID + "…")
			m.send(map[string]any{"cmd": "rm", "id": c.ID})
		}
	case "save":
		p := d.(*PromptDialog)
		value := strings.TrimSpace(p.Value)
		if p.Kind == "alias" {
			m.send(map[string]any{"cmd": "set_alias", "id": p.ID, "value": value})
		} else {
			m.send(map[string]any{"cmd": "set_pr", "id": p.ID, "value": value})
		}
		m.dialog = nil
	}
	return m, nil
}

func (m Model) handleLineKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		if m.command != nil {
			m.command = nil
		} else {
			m.filter = ""
			m.filterEditing = false
		}
	case "enter":
		if m.command != nil {
			line := *m.command
			m.command = nil
			return m.perform(CommandAction(line))
		}
		m.filterEditing = false
	case "backspace", "ctrl+h":
		if m.command != nil {
			if *m.command == "" {
				m.command = nil
			} else {
				*m.command = dropLast(*m.command)
			}
		} else if m.filter == "" {
			m.filterEditing = false
		} else {
			m.filter = dropLast(m.filter)
		}
	default:
		if msg.Type == tea.KeyRunes && !msg.Alt {
			if m.command != nil {
				*m.command += string(msg.Runes)
			} else {
				m.filter += string(msg.Runes)
			}
		}
	}
	return m, nil
}

func (m Model) openForm() (tea.Model, tea.Cmd) {
	cwd := ""
	if r := m.selectedRow(); r != nil {
		cwd = r.Cwd
	}
	m.form = NewForm(cwd, m.width, m.height-2)
	return m, m.form.Ask(m.backend)
}

func (m Model) handleFormKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	outcome, cmd := m.form.Press(msg, m.backend)
	switch outcome {
	case "cancel":
		m.form = nil
	case "start", "start_and_attach":
		values := m.form.Values()
		values["cmd"] = "spawn"
		values["attach"] = outcome == "start_and_attach"
		m.form = nil
		m.setNotice("starting session…")
		m.send(values)
	}
	return m, cmd
}

func dropLast(s string) string {
	r := []rune(s)
	if len(r) == 0 {
		return s
	}
	return string(r[:len(r)-1])
}

func contains(list []string, s string) bool { return index(list, s) >= 0 }

func index(list []string, s string) int {
	for i, v := range list {
		if v == s {
			return i
		}
	}
	return -1
}

func clamp(v, lo, hi int) int { return max(lo, min(v, hi)) }
