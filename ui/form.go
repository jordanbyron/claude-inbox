package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	models          = []string{"default", "fable", "opus", "sonnet", "haiku"}
	efforts         = []string{"default", "low", "medium", "high", "xhigh", "max"}
	permissionModes = []string{"default", "acceptEdits", "auto", "plan", "bypassPermissions"}
)

const menuRows = 6

type choiceField struct {
	key, label string
	choices    []string
	value      string
}

func (f *choiceField) cycle(d int) {
	i := index(f.choices, f.value)
	n := len(f.choices)
	f.value = f.choices[((i+d)%n+n)%n]
}

// Form is the new-session screen. Everything the CLI would resolve on its
// own (settings defaults, the slash commands on offer) is asked of the
// backend, since it reads the same files `claude` does.
type Form struct {
	prompt   textarea.Model
	name     textinput.Model
	cwd      textinput.Model
	choices  []*choiceField
	focus    int
	errText  string
	defaults DefaultsMsg
	commands []Command
	askedFor string
	pick     int
	dismiss  string
	width    int
	height   int
}

var commandQuery = regexp.MustCompile(`(?:^|\s)/(\S*)$`)

func NewForm(cwd string, width, height int) *Form {
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	ta := textarea.New()
	ta.Placeholder = "What should this session do?"
	ta.ShowLineNumbers = false
	ta.Prompt = ""
	ta.CharLimit = 0
	ta.Focus()
	name := textinput.New()
	name.Placeholder = "(none — claude picks one)"
	name.Prompt = ""
	dir := textinput.New()
	dir.Prompt = ""
	dir.SetValue(cwd)
	f := &Form{
		prompt: ta, name: name, cwd: dir,
		choices: []*choiceField{
			{"model", "Model", models, "default"},
			{"effort", "Effort", efforts, "default"},
			{"permission_mode", "Permissions", permissionModes, "default"},
			{"worktree", "Worktree", []string{"no", "yes"}, "no"},
		},
	}
	f.Resize(width, height)
	return f
}

func (f *Form) fieldCount() int { return 3 + len(f.choices) }

func (f *Form) Resize(width, height int) {
	f.width, f.height = width, height
	f.prompt.SetWidth(width - 6)
	f.prompt.SetHeight(max(height-(6+len(f.choices))-menuRows, 3))
	f.name.Width = width - 20
	f.cwd.Width = width - 20
}

func (f *Form) Ask(b *Backend) tea.Cmd {
	cwd := f.Values()["cwd"].(string)
	if cwd == f.askedFor {
		return nil
	}
	f.askedFor = cwd
	b.Send(map[string]any{"cmd": "defaults", "cwd": cwd})
	b.Send(map[string]any{"cmd": "commands", "cwd": cwd})
	return nil
}

func (f *Form) Receive(msg tea.Msg) {
	switch msg := msg.(type) {
	case DefaultsMsg:
		f.defaults = msg
	case CommandsMsg:
		f.commands = msg.Commands
	}
}

func (f *Form) Values() map[string]any {
	cwd := strings.TrimSpace(f.cwd.Value())
	if cwd == "" {
		cwd = "."
	}
	if strings.HasPrefix(cwd, "~") {
		home, _ := os.UserHomeDir()
		cwd = home + cwd[1:]
	}
	cwd, _ = filepath.Abs(cwd)
	v := map[string]any{
		"prompt": strings.TrimSpace(f.prompt.Value()),
		"cwd":    cwd,
	}
	if name := strings.TrimSpace(f.name.Value()); name != "" {
		v["name"] = name
	}
	for _, c := range f.choices {
		if c.key == "worktree" {
			v[c.key] = c.value == "yes"
		} else {
			v[c.key] = c.value
		}
	}
	return v
}

func (f *Form) queryBeforeCursor() (string, bool) {
	if f.focus != 0 {
		return "", false
	}
	head := f.textBeforeCursor()
	m := commandQuery.FindStringSubmatch(head)
	if m == nil {
		return "", false
	}
	return m[1], true
}

func (f *Form) textBeforeCursor() string {
	lines := strings.Split(f.prompt.Value(), "\n")
	row := f.prompt.Line()
	if row >= len(lines) {
		return f.prompt.Value()
	}
	col := f.prompt.LineInfo().ColumnOffset
	runes := []rune(lines[row])
	col = clamp(col, 0, len(runes))
	return strings.Join(lines[:row], "\n") + "\n" + string(runes[:col])
}

func (f *Form) menu() []Command {
	q, ok := f.queryBeforeCursor()
	if !ok || f.dismiss == q {
		return nil
	}
	lq := strings.ToLower(q)
	var starts, rest []Command
	for _, c := range f.commands {
		name := strings.ToLower(c.Name)
		if strings.HasPrefix(name, "/"+lq) {
			starts = append(starts, c)
		} else if strings.Contains(name, lq) {
			rest = append(rest, c)
		}
	}
	return append(starts, rest...)
}

func (f *Form) Press(msg tea.KeyMsg, b *Backend) (string, tea.Cmd) {
	f.errText = ""
	if items := f.menu(); items != nil {
		if handled := f.menuPress(msg, items); handled {
			return "", nil
		}
	}
	switch msg.String() {
	case "esc":
		return "cancel", nil
	case "ctrl+s":
		return f.submit(false), nil
	case "ctrl+o":
		return f.submit(true), nil
	case "tab":
		if f.focus == 2 && f.completeDir() {
			return "", nil
		}
		f.move(1)
		return "", f.Ask(b)
	case "shift+tab":
		f.move(-1)
		return "", f.Ask(b)
	case "enter":
		if f.focus != 0 {
			f.move(1)
			return "", f.Ask(b)
		}
	case "down":
		if f.focus != 0 {
			f.move(1)
			return "", f.Ask(b)
		}
	case "up":
		if f.focus != 0 {
			f.move(-1)
			return "", f.Ask(b)
		}
	}
	if f.focus >= 3 {
		f.choose(msg)
		return "", nil
	}
	var cmd tea.Cmd
	before, _ := f.queryBeforeCursor()
	switch f.focus {
	case 0:
		f.prompt, cmd = f.prompt.Update(msg)
	case 1:
		f.name, cmd = f.name.Update(msg)
	case 2:
		f.cwd, cmd = f.cwd.Update(msg)
	}
	if after, _ := f.queryBeforeCursor(); after != before {
		f.pick = 0
		f.dismiss = ""
	}
	return "", cmd
}

func (f *Form) menuPress(msg tea.KeyMsg, items []Command) bool {
	n := len(items)
	switch msg.String() {
	case "up", "ctrl+p":
		f.pick = ((f.pick-1)%n + n) % n
	case "down", "ctrl+n":
		f.pick = (f.pick + 1) % n
	case "tab", "enter":
		f.accept(items[clamp(f.pick, 0, n-1)])
	case "esc":
		f.dismiss, _ = f.queryBeforeCursor()
	default:
		return false
	}
	return true
}

func (f *Form) accept(c Command) {
	q, _ := f.queryBeforeCursor()
	head := f.textBeforeCursor()
	tail := strings.TrimPrefix(f.prompt.Value(), head)
	head = head[:len(head)-len(q)-1] + c.Name + " "
	f.prompt.SetValue(head + tail)
	f.prompt.SetCursor(len([]rune(strings.TrimPrefix(head, strings.Join(strings.Split(head, "\n")[:strings.Count(head, "\n")], "\n")))))
	f.pick = 0
}

func (f *Form) move(d int) {
	f.blur()
	n := f.fieldCount()
	f.focus = ((f.focus+d)%n + n) % n
	switch f.focus {
	case 0:
		f.prompt.Focus()
	case 1:
		f.name.Focus()
	case 2:
		f.cwd.Focus()
	}
}

func (f *Form) blur() {
	f.prompt.Blur()
	f.name.Blur()
	f.cwd.Blur()
}

func (f *Form) choose(msg tea.KeyMsg) {
	c := f.choices[f.focus-3]
	switch msg.String() {
	case "left", "h":
		c.cycle(-1)
	case "right", "l", " ":
		c.cycle(1)
	}
}

func (f *Form) completeDir() bool {
	typed := f.cwd.Value()
	base := typed
	if base == "" {
		base = "."
	}
	if strings.HasPrefix(base, "~") {
		home, _ := os.UserHomeDir()
		base = home + base[1:]
	}
	base, _ = filepath.Abs(base)
	listing := typed == "" || strings.HasSuffix(typed, "/")
	if st, err := os.Stat(base); !listing && err == nil && st.IsDir() {
		return false
	}
	pattern := base + "*"
	if listing {
		pattern = base + "/*"
	}
	found, _ := filepath.Glob(pattern)
	var dirs []string
	for _, d := range found {
		if st, err := os.Stat(d); err == nil && st.IsDir() {
			dirs = append(dirs, d)
		}
	}
	if len(dirs) == 0 {
		return false
	}
	sort.Strings(dirs)
	if len(dirs) == 1 {
		f.cwd.SetValue(dirs[0] + "/")
	} else {
		f.cwd.SetValue(commonPrefix(dirs))
	}
	f.cwd.CursorEnd()
	return true
}

func commonPrefix(paths []string) string {
	first := paths[0]
	for i := range first {
		for _, p := range paths[1:] {
			if i >= len(p) || p[i] != first[i] {
				return first[:i]
			}
		}
	}
	return first
}

func (f *Form) submit(attach bool) string {
	v := f.Values()
	if v["prompt"] == "" {
		f.errText = "a prompt is required"
		f.blur()
		f.focus = 0
		f.prompt.Focus()
		return ""
	}
	if st, err := os.Stat(v["cwd"].(string)); err != nil || !st.IsDir() {
		f.errText = "no such directory: " + v["cwd"].(string)
		f.blur()
		f.focus = 2
		f.cwd.Focus()
		return ""
	}
	if attach {
		return "start_and_attach"
	}
	return "start"
}

func (f *Form) View() string {
	var b strings.Builder
	b.WriteString("\n  " + titleStyle.Render("New session") + "\n\n")
	b.WriteString("  " + f.label("Prompt", 0) + dimStyle.Render("  ⏎ newline") + "\n")
	edge := dimStyle
	if f.focus == 0 {
		edge = colored(cyan)
	}
	b.WriteString(lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(edge.GetForeground()).
		Padding(0, 1).MarginLeft(2).Width(f.width-6).Render(f.prompt.View()) + "\n")
	for _, line := range f.menuLines() {
		b.WriteString(line + "\n")
	}
	b.WriteString("\n")
	b.WriteString("  " + f.label("Name", 1) + f.name.View() + "\n")
	b.WriteString("  " + f.label("Directory", 2) + f.cwd.View() + "\n")
	for i, c := range f.choices {
		b.WriteString("  " + f.label(c.label, 3+i) + f.choiceView(c, f.focus == 3+i) + "\n")
	}
	return b.String()
}

func (f *Form) label(text string, idx int) string {
	padded := lipgloss.NewStyle().Width(12).Render(text)
	if f.focus == idx {
		return keyStyle.Render("▶ ") + titleStyle.Render(padded)
	}
	return "  " + dimStyle.Render(padded)
}

func (f *Form) choiceView(c *choiceField, on bool) string {
	var parts []string
	for _, choice := range c.choices {
		text := choice
		if choice == "default" {
			text = f.defaultText(c.key)
		}
		switch {
		case choice == c.value && on:
			parts = append(parts, lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(cyan).Render(" "+text+" "))
		case choice == c.value:
			parts = append(parts, keyStyle.Render(" "+text+" "))
		default:
			parts = append(parts, dimStyle.Render(" "+text+" "))
		}
	}
	return strings.Join(parts, " ")
}

func (f *Form) defaultText(key string) string {
	resolved := ""
	switch key {
	case "model":
		resolved = f.defaults.Model
	case "effort":
		resolved = f.defaults.Effort
	case "permission_mode":
		resolved = f.defaults.PermissionMode
	}
	if resolved != "" {
		return resolved + " (settings)"
	}
	return "auto (cli default)"
}

func (f *Form) menuLines() []string {
	items := f.menu()
	if items == nil {
		return nil
	}
	pick := clamp(f.pick, 0, len(items)-1)
	first := max(pick-menuRows+1, 0)
	shown := items[first:min(first+menuRows, len(items))]
	var out []string
	for i, c := range shown {
		name := lipgloss.NewStyle().Width(28).Render(c.Name)
		if first+i == pick {
			out = append(out, "    "+lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(cyan).Render(" "+name+" ")+" "+c.Description)
		} else {
			out = append(out, "    "+keyStyle.Render(" "+name+" ")+" "+dimStyle.Render(c.Description))
		}
	}
	if left := len(items) - first - len(shown); left > 0 {
		out[len(out)-1] += dimStyle.Render("  +" + itoa(left) + " more")
	}
	return out
}

func (f *Form) Footer() string {
	if f.errText != "" {
		return colored(red).Render(f.errText)
	}
	if f.menu() != nil {
		return keys([][2]string{{"↑ ↓", "choose"}, {"⇥ ⏎", "pick"}, {"esc", "close"}})
	}
	var k [][2]string
	switch {
	case f.focus == 0:
		k = [][2]string{{"⏎", "newline"}}
	case f.focus >= 3:
		k = [][2]string{{"← → h l", "change"}, {"⏎", "next"}}
	default:
		k = [][2]string{{"⏎", "next"}}
	}
	next := "next"
	if f.focus == 2 {
		next = "complete / next"
	}
	k = append(k, [2]string{"^S", "start"}, [2]string{"^O", "start & open"}, [2]string{"⇥", next}, [2]string{"esc", "cancel"})
	return keys(k)
}

func keys(pairs [][2]string) string {
	var parts []string
	for _, p := range pairs {
		parts = append(parts, keyStyle.Render(p[0])+" "+dimStyle.Render(p[1]))
	}
	return strings.Join(parts, "  ")
}
