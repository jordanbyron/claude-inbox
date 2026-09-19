package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

var quips = []string{
	"asking the daemon nicely…", "counting agents…", "reticulating splines…", "herding sessions…",
	"checking behind the couch…", "reading the process tree…", "polishing the spinner…", "still here…",
}

var footerKeys = [][2]string{
	{"j/k", "move"}, {"⏎", "attach"}, {"n", "new"}, {"t", "pin"}, {"s", "snooze"}, {"u", "wake"},
	{"a", "alias"}, {"o", "PR"}, {"x", "settle"}, {"p", "peek"}, {"⇥", "section"},
	{"za", "fold"}, {"/", "filter"}, {"?", "help"}, {":q", "quit"},
}

const (
	loadingQuiet     = 1500 * time.Millisecond
	loadingHintAfter = 10 * time.Second
	minListWidth     = 44
)

func itoa(n int) string { return strconv.Itoa(n) }

func pad(s string, w int) string {
	if ansi.StringWidth(s) > w {
		return ansi.Truncate(s, w, "…")
	}
	return s + strings.Repeat(" ", w-ansi.StringWidth(s))
}

func (m Model) View() string {
	if m.width == 0 {
		return ""
	}
	viewH := m.height - 2
	var body []string
	var footer string
	if m.form != nil {
		body = strings.Split(strings.TrimRight(m.form.View(), "\n"), "\n")
		footer = " " + m.form.Footer()
		m.lineKeys = nil
	} else {
		body = m.bodyWithPeek(viewH)
		footer = m.footer()
	}
	body = fit(body, viewH)
	for i := range body {
		body[i] = pad(body[i], m.width)
	}
	if m.dialog != nil {
		body = overlay(body, strings.Split(m.dialog.View(m.width), "\n"), m.width)
	}
	return m.header() + "\n" + strings.Join(body, "\n") + "\n" + pad(footer, m.width)
}

func fit(lines []string, h int) []string {
	if len(lines) > h {
		lines = lines[:h]
	}
	for len(lines) < h {
		lines = append(lines, "")
	}
	return lines
}

func (m *Model) bodyWithPeek(viewH int) []string {
	listW := m.width
	if m.peekOpen && m.selected != "" && !foldable(m.selected) {
		listW = clamp(max(int(float64(m.width)*0.4), minListWidth), 0, m.width)
	}
	m.listWidth = listW
	lines, keysByLine := m.listLines(listW)
	m.top = clampTop(m.top, len(lines), viewH, keysByLine, m.selected)
	visible := fit(sliceFrom(lines, m.top, viewH), viewH)
	m.lineKeys = append([]string{""}, fit(sliceFrom(keysByLine, m.top, viewH), viewH)...)
	if listW == m.width {
		return visible
	}
	peekW := m.width - listW - 1
	peek := fit(m.peekPane(peekW, viewH), viewH)
	for i := range visible {
		visible[i] = pad(visible[i], listW) + dimStyle.Render("│") + pad(peek[i], peekW)
	}
	return visible
}

func sliceFrom(lines []string, top, n int) []string {
	if top >= len(lines) {
		return nil
	}
	return lines[top:min(top+n, len(lines))]
}

func clampTop(top, size, viewH int, keys []string, selected string) int {
	idx := index(keys, selected)
	if idx >= 0 && idx-2 < top {
		top = idx - 2
	}
	if idx >= 0 && idx >= top+viewH {
		top = idx - viewH + 1
	}
	return clamp(top, 0, max(size-viewH, 0))
}

func (m Model) header() string {
	brand := " " + brandStyle.Render("▌ claude-inbox")
	right := dimStyle.Render(m.statusText()) + " "
	room := m.width - ansi.StringWidth(brand) - ansi.StringWidth(right) - 3
	chips := ""
	if m.polled {
		chips = m.headerChips(false)
		if ansi.StringWidth(chips) > room {
			chips = m.headerChips(true)
		}
		if ansi.StringWidth(chips) > room {
			chips = ""
		}
	}
	return pad(brand+"   "+chips, m.width-ansi.StringWidth(right)) + right
}

func (m Model) headerChips(compact bool) string {
	s := m.sections
	count := func(rows []Row, f func(Row) bool) int {
		n := 0
		for _, r := range rows {
			if f(r) {
				n++
			}
		}
		return n
	}
	chip := func(n int, glyph, word string, style lipgloss.Style) string {
		if n == 0 {
			return ""
		}
		if compact {
			return style.Render(glyph + " " + itoa(n))
		}
		return style.Render(glyph + " " + itoa(n) + " " + word)
	}
	needs := len(s.Get("needs_you"))
	needWord := "need you"
	if needs == 1 {
		needWord = "needs you"
	}
	terminals := count(s.All(), func(r Row) bool { return r.Terminal })
	var chips []string
	for _, c := range []string{
		chip(len(s.Get("pinned")), "★", "pinned", brandStyle),
		chip(needs, "●", needWord, colored(red).Bold(true)),
		chip(count(s.Get("active"), func(r Row) bool { return r.State == "working" && !r.WaitingOnWork }), "✻", "working", colored(yellow)),
		chip(count(s.Get("active"), func(r Row) bool { return r.WaitingOnWork }), "◌", "idle", colored(yellow)),
		chip(terminals, "○", plural("terminal", terminals), dimStyle),
		chip(count(s.All(), func(r Row) bool { return r.Remote }), "⇅", "remote", colored(blue)),
		chip(len(s.Get("snoozed")), "z", "snoozed", colored(magenta)),
		chip(len(s.Get("settled")), "◦", "settled", dimStyle),
	} {
		if c != "" {
			chips = append(chips, c)
		}
	}
	if s.Empty() {
		chips = append(chips, dimStyle.Render("nothing running"))
	}
	if compact {
		return strings.Join(chips, "  ")
	}
	return strings.Join(chips, dimStyle.Render("  ·  "))
}

func (m Model) statusText() string {
	now := time.Now()
	if m.notice != "" && now.Before(m.noticeTo) {
		return m.notice
	}
	if m.errText != "" {
		return "⚠ " + m.errText
	}
	if m.lastPoll.IsZero() {
		return "polling…"
	}
	return "⟳ " + age(int64(now.Sub(m.lastPoll).Seconds())) + " ago"
}

func (m Model) footer() string {
	switch {
	case m.command != nil:
		return " " + keyStyle.Render(":") + *m.command + dimStyle.Render("▏")
	case m.filterEditing:
		return " " + keyStyle.Render("/") + m.filter + dimStyle.Render("▏")
	case m.filter != "":
		return " " + keyStyle.Render("/") + m.filter + dimStyle.Render("  esc clears")
	case m.keymap.Pending() != "":
		return " " + keyStyle.Render(m.keymap.Pending()) + dimStyle.Render("…")
	}
	return " " + keys(footerKeys)
}

func (m Model) listLines(width int) ([]string, []string) {
	if !m.polled {
		return m.loadingState(width, m.height-2), nil
	}
	sections := m.filtered()
	if sections.Empty() {
		return m.emptyState(), nil
	}
	var lines, keysByLine []string
	add := func(line, key string) {
		lines = append(lines, line)
		keysByLine = append(keysByLine, key)
	}
	now := time.Now().Unix()
	for _, name := range sectionOrder {
		rows := sections.Get(name)
		if len(rows) == 0 {
			continue
		}
		add("", "")
		add(m.sectionTitle(name, len(rows), width), "")
		if sections.Folded(name, m.expanded) {
			add(m.foldToggleLine(name, len(rows), width), name)
			continue
		}
		for _, r := range rows {
			rowLines := m.rowLines(r, name, width, now)
			key := ""
			if r.Selectable {
				key = r.Key
			}
			add(rowLines[0], key)
			for _, l := range rowLines[1:] {
				add(l, "")
			}
		}
	}
	return lines, keysByLine
}

func (m Model) sectionTitle(name string, count, width int) string {
	title := " " + sectionTitles[name] + " "
	countS := " " + itoa(count) + " "
	fill := max(width-3-ansi.StringWidth(title)-ansi.StringWidth(countS), 0)
	color := colored(sectionColors[name])
	return " " + color.Render("▎") + color.Bold(true).Render(title) + dimStyle.Render(strings.Repeat("─", fill)) + dimStyle.Render(countS)
}

func (m Model) foldToggleLine(name string, count, width int) string {
	sel := m.selected == name
	marker := " "
	hint := ""
	if sel {
		marker = keyStyle.Render("▶")
		hint = dimStyle.Render("   ⏎ or zo to expand")
	}
	return " " + marker + " " + dimStyle.Render("… "+itoa(count)+" "+strings.ToLower(sectionTitles[name])) + hint
}

func (m Model) rowLines(r Row, section string, width int, now int64) []string {
	sel := r.Selectable && m.selected == r.Key
	marker := " "
	if sel {
		marker = keyStyle.Render("▶")
	}
	glyph := m.glyph(r, section)
	meta := m.meta(r, section, now)
	chrome := 1 + 1 + 1 + 1 + 1 + 2 + ansi.StringWidth(meta) + 2
	projectText := ansi.Truncate(r.Project, max(width-chrome, 0), "…")
	project := colored(cyan).Render(projectText)
	if section == "settled" {
		project = dimStyle.Render(projectText)
	}
	labelW := max(width-chrome-ansi.StringWidth(projectText), 0)
	label := m.styleLabel(pad(ansi.Truncate(r.Label, labelW, "…"), labelW), r, section, sel)
	first := " " + marker + " " + glyph + " " + label + "  " + meta + "  " + project
	if sel {
		first = selectedBg.Render(pad(first, width))
	}
	if section != "pinned" && section != "needs_you" && section != "active" {
		return []string{first}
	}
	return []string{first, dimStyle.Render("       ↳ " + shortPath(r.Cwd))}
}

// The label is the one part of a row `/color` may tint; glyph, badge and
// PR keep the state's colors so no color can make a blocked session stop
// looking blocked.
func (m Model) styleLabel(label string, r Row, section string, sel bool) string {
	if section == "settled" {
		return dimStyle.Render(label)
	}
	st := lipgloss.NewStyle()
	if r.Aliased {
		st = st.Italic(true)
	}
	if sel {
		st = st.Bold(true)
	}
	if c, ok := paletteColor(r.Color); ok {
		st = st.Foreground(c)
	}
	return st.Render(label)
}

func (m Model) glyph(r Row, section string) string {
	switch section {
	case "snoozed":
		return colored(magenta).Render("z")
	case "settled":
		return dimStyle.Render("◦")
	}
	switch r.State {
	case "blocked":
		return colored(red).Bold(true).Render("●")
	case "failed":
		return colored(red).Bold(true).Render("✗")
	case "working":
		if r.WaitingOnWork {
			return colored(yellow).Render("◌")
		}
		return colored(yellow).Render(spinner[(m.tick/2)%len(spinner)])
	case "done":
		return colored(green).Render("✓")
	case "stopped":
		return dimStyle.Render("■")
	}
	return dimStyle.Render("?")
}

func (m Model) meta(r Row, section string, now int64) string {
	var base string
	switch section {
	case "snoozed":
		if r.Parked {
			base = colored(magenta).Render("parked")
		} else {
			base = colored(magenta).Render("wakes in " + age(r.WakeAt-now))
		}
	case "settled":
		base = dimStyle.Render(r.State + " · " + age(now-r.StateSince))
	default:
		if r.Interactive {
			where := "your terminal"
			if r.Remote {
				where = "remote"
			}
			since := r.StateSince
			if since == 0 {
				since = r.StartedAt
			}
			base = m.stateBadge(r) + dimStyle.Render(" · "+where+" · "+age(now-since))
		} else {
			base = m.stateBadge(r)
			if r.StateSince != 0 {
				base += dimStyle.Render(" · " + age(now-r.StateSince))
			}
		}
	}
	if pr := m.prBadge(r, section); pr != "" {
		return base + dimStyle.Render(" · ") + pr
	}
	return base
}

func (m Model) prBadge(r Row, section string) string {
	pr := r.PR()
	if pr == nil {
		return ""
	}
	if section == "settled" {
		return dimStyle.Render(strings.TrimSpace(pr.Short + " " + strings.ToLower(pr.State)))
	}
	switch pr.State {
	case "OPEN":
		return colored(green).Render(pr.Short + " open")
	case "DRAFT":
		return dimStyle.Render(pr.Short + " draft")
	case "MERGED":
		return colored(magenta).Render(pr.Short + " merged")
	case "CLOSED":
		return colored(red).Render(pr.Short + " closed")
	}
	return dimStyle.Render(pr.Short)
}

func (m Model) stateBadge(r Row) string {
	switch r.State {
	case "blocked":
		detail := ""
		if r.WaitingFor != "" {
			detail = ": " + r.WaitingFor
		}
		return colored(red).Bold(true).Render("needs you" + detail)
	case "failed":
		return colored(red).Bold(true).Render("failed")
	case "working":
		return m.workingBadge(r)
	case "done":
		out := colored(green).Render("done")
		if r.Alive && !r.Interactive {
			out += dimStyle.Render(" · " + r.Status)
		}
		return out
	case "stopped":
		return dimStyle.Render("stopped")
	}
	return dimStyle.Render(r.State)
}

func (m Model) workingBadge(r Row) string {
	if r.Status == "waiting" {
		if r.WaitingFor != "" {
			return colored(yellow).Render("waiting: " + r.WaitingFor)
		}
		return colored(yellow).Render("waiting")
	}
	word := "working"
	if r.WaitingOnWork {
		word = "idle"
	}
	out := colored(yellow).Render(word)
	if r.InFlight != "" {
		out += dimStyle.Render(" · " + r.InFlight)
	}
	return out
}

func shortPath(path string) string {
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(path, home) {
		return "~" + path[len(home):]
	}
	return path
}

func (m Model) loadingState(width, height int) []string {
	waited := time.Since(m.bootedAt)
	if waited < loadingQuiet {
		return nil
	}
	block := []string{
		centered(brandStyle.Render(spinner[(m.tick/2)%len(spinner)]), width),
		"",
		centered(tray(m.tick/2), width),
		"",
		centered(quips[(m.tick/12)%len(quips)], width),
		centered(dimStyle.Render(fmt.Sprintf("waiting on claude agents · %ds", int(waited.Seconds()))), width),
	}
	if waited >= loadingHintAfter {
		block = append(block, "", centered(dimStyle.Render("slow? ")+colored(cyan).Render("claude daemon status")+dimStyle.Render(" says whether the daemon is up"), width))
	}
	top := max((height-len(block))/2, 0)
	return append(make([]string, top), block...)
}

const traySlots = 9

func tray(tick int) string {
	span := traySlots - 1
	i := tick % (span * 2)
	pos := i
	if i > span {
		pos = span*2 - i
	}
	cells := make([]string, traySlots)
	for j := range cells {
		if j == pos {
			cells[j] = brandStyle.Render("●")
		} else {
			cells[j] = dimStyle.Render("·")
		}
	}
	return dimStyle.Render("▌") + " " + strings.Join(cells, " ") + " " + dimStyle.Render("▐")
}

func centered(s string, width int) string {
	left := max((width-ansi.StringWidth(s))/2, 0)
	return strings.Repeat(" ", left) + s
}

func (m Model) emptyState() []string {
	return []string{
		"", "",
		"   " + titleStyle.Render("Nothing running."),
		"   " + dimStyle.Render("Start one from any terminal with ") + colored(cyan).Render("claude --bg \"task\""),
		"   " + dimStyle.Render("or press ") + colored(cyan).Render("R") + dimStyle.Render(" to poll again."),
	}
}

func (m Model) peekPane(width, height int) []string {
	r := m.selectedRow()
	title := m.selected
	if r != nil {
		title = r.Label
	}
	out := []string{peekBar.Render(pad(" "+title, width))}
	if r != nil {
		out = append(out, dimStyle.Render(" "+m.peekSubtitle(*r)))
	}
	bodyH := height - len(out)
	var wrapped []string
	for _, l := range m.peekBody(r) {
		wrapped = append(wrapped, strings.Split(ansi.Wordwrap(l, width-1, ""), "\n")...)
	}
	end := len(wrapped)
	if m.peekOffset > 0 {
		end = max(len(wrapped)-min(m.peekOffset, max(len(wrapped)-bodyH, 0)), 0)
	}
	start := max(end-bodyH, 0)
	for _, l := range wrapped[start:end] {
		out = append(out, " "+l)
	}
	return out
}

func (m Model) peekBody(r *Row) []string {
	if r == nil {
		return []string{"(nothing selected)"}
	}
	if r.Interactive {
		note := "This is a claude you opened in a terminal yourself. The daemon can't attach to it, read its output, or stop it from outside. Switch to that window."
		if r.Remote {
			note = "This is a Remote Control session driven from claude.ai/code. The daemon can't attach to it or read its output from here. Open it in the web or mobile app instead."
		}
		return []string{note, "", "pid " + itoa(r.Pid) + " · " + r.Cwd, "session " + r.SessionID}
	}
	if lines, ok := m.peekLines[r.ID]; ok {
		return lines
	}
	return []string{"(loading…)"}
}

func (m Model) peekSubtitle(r Row) string {
	parts := []string{r.State}
	for _, p := range []string{r.Status, r.WaitingFor, r.ID} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	if r.StartedAt != 0 {
		parts = append(parts, time.Unix(r.StartedAt, 0).Format("started Jan 2 15:04"))
	}
	for _, pr := range r.PRs {
		state := "?"
		if pr.State != "" {
			state = strings.ToLower(pr.State)
		}
		parts = append(parts, pr.Short+" "+state)
	}
	return strings.Join(parts, " · ")
}

func overlay(lines, block []string, width int) []string {
	blockW := 0
	for _, l := range block {
		blockW = max(blockW, ansi.StringWidth(l))
	}
	left := max((width-blockW)/2, 0)
	top := max((len(lines)-len(block))/2, 0)
	out := append([]string{}, lines...)
	for i, bl := range block {
		y := top + i
		if y >= len(out) {
			break
		}
		base := ansi.Strip(out[y])
		prefix := pad(ansi.Truncate(base, left, ""), left)
		suffix := ansi.TruncateLeft(base, left+blockW, "")
		out[y] = pad(dimStyle.Render(prefix)+pad(bl, blockW)+dimStyle.Render(suffix), width)
	}
	return out
}
