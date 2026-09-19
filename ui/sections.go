package main

import (
	"fmt"
	"strings"
)

var sectionOrder = []string{"pinned", "needs_you", "active", "snoozed", "settled"}

var sectionTitles = map[string]string{
	"pinned": "PINNED", "needs_you": "NEEDS YOU", "active": "ACTIVE", "snoozed": "SNOOZED", "settled": "SETTLED",
}

func foldable(name string) bool { return name == "snoozed" || name == "settled" }

type Sections struct {
	list []Section
}

func (s Sections) Get(name string) []Row {
	for _, sec := range s.list {
		if sec.Name == name {
			return sec.Rows
		}
	}
	return nil
}

func (s Sections) All() []Row {
	var out []Row
	for _, name := range sectionOrder {
		out = append(out, s.Get(name)...)
	}
	return out
}

func (s Sections) Empty() bool { return len(s.All()) == 0 }

func (s Sections) Row(key string) *Row {
	for _, sec := range s.list {
		for i := range sec.Rows {
			if sec.Rows[i].Key == key {
				return &sec.Rows[i]
			}
		}
	}
	return nil
}

// Kept in step with Row#matches? in the Ruby.
func (s Sections) Matching(query string) Sections {
	if query == "" {
		return s
	}
	q := strings.ToLower(query)
	out := Sections{}
	for _, sec := range s.list {
		kept := Section{Name: sec.Name}
		for _, r := range sec.Rows {
			if strings.Contains(strings.ToLower(r.Label), q) || strings.Contains(strings.ToLower(r.Cwd), q) {
				kept.Rows = append(kept.Rows, r)
			}
		}
		out.list = append(out.list, kept)
	}
	return out
}

func (s Sections) Folded(name string, expanded map[string]bool) bool {
	return foldable(name) && !expanded[name]
}

func (s Sections) SectionOf(key string) string {
	if foldable(key) {
		return key
	}
	for _, sec := range s.list {
		for _, r := range sec.Rows {
			if r.Key == key {
				return sec.Name
			}
		}
	}
	return ""
}

type stop struct {
	name string
	rows []Row
	fold bool
}

func (s Sections) stops(expanded map[string]bool) []stop {
	var out []stop
	for _, name := range sectionOrder {
		rows := s.Get(name)
		if !s.Folded(name, expanded) {
			var sel []Row
			for _, r := range rows {
				if r.Selectable {
					sel = append(sel, r)
				}
			}
			out = append(out, stop{name: name, rows: sel})
		} else if len(rows) > 0 {
			out = append(out, stop{name: name, fold: true})
		}
	}
	return out
}

func (s Sections) SelectableKeys(expanded map[string]bool) []string {
	var keys []string
	for _, st := range s.stops(expanded) {
		if st.fold {
			keys = append(keys, st.name)
			continue
		}
		for _, r := range st.rows {
			keys = append(keys, r.Key)
		}
	}
	return keys
}

func (s Sections) Heads(expanded map[string]bool) [][2]string {
	var out [][2]string
	for _, st := range s.stops(expanded) {
		if st.fold {
			out = append(out, [2]string{st.name, st.name})
		} else if len(st.rows) > 0 {
			out = append(out, [2]string{st.name, st.rows[0].Key})
		}
	}
	return out
}

func age(seconds int64) string {
	switch {
	case seconds <= 0:
		return "0s"
	case seconds < 60:
		return fmt.Sprintf("%ds", seconds)
	case seconds < 3600:
		return fmt.Sprintf("%dm", seconds/60)
	case seconds < 86400:
		return fmt.Sprintf("%dh", seconds/3600)
	}
	return fmt.Sprintf("%dd", seconds/86400)
}

func plural(word string, n int) string {
	if n == 1 {
		return word
	}
	return word + "s"
}
