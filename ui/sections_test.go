package main

import (
	"reflect"
	"testing"
)

func fixture() Sections {
	return Sections{list: []Section{
		{Name: "pinned"},
		{Name: "needs_you", Rows: []Row{{Key: "aaa", Label: "blocked one", Cwd: "/x/proj", Selectable: true}}},
		{Name: "active", Rows: []Row{
			{Key: "term-uuid", Label: "claude-inbox-1", Cwd: "/x/inbox", Selectable: true, Terminal: true},
			{Key: "bbb", Label: "working one", Cwd: "/x/proj", Selectable: true},
		}},
		{Name: "snoozed", Rows: []Row{{Key: "ccc", Label: "napping", Cwd: "/x/proj", Selectable: true}}},
		{Name: "settled"},
	}}
}

func TestSelectableKeysStopOnAFold(t *testing.T) {
	keys := fixture().SelectableKeys(map[string]bool{})
	want := []string{"aaa", "term-uuid", "bbb", "snoozed"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("got %v want %v", keys, want)
	}
}

func TestSelectableKeysWalkAnOpenFold(t *testing.T) {
	keys := fixture().SelectableKeys(map[string]bool{"snoozed": true})
	want := []string{"aaa", "term-uuid", "bbb", "ccc"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("got %v want %v", keys, want)
	}
}

func TestHeadsSkipEmptySections(t *testing.T) {
	heads := fixture().Heads(map[string]bool{})
	want := [][2]string{{"needs_you", "aaa"}, {"active", "term-uuid"}, {"snoozed", "snoozed"}}
	if !reflect.DeepEqual(heads, want) {
		t.Fatalf("got %v want %v", heads, want)
	}
}

func TestMatchingSearchesLabelAndDirectory(t *testing.T) {
	got := fixture().Matching("inbox").SelectableKeys(map[string]bool{})
	if !reflect.DeepEqual(got, []string{"term-uuid"}) {
		t.Fatalf("got %v", got)
	}
	if fixture().Matching("ONE").Get("active")[0].Key != "bbb" {
		t.Fatal("filter should ignore case")
	}
}

func TestSectionOfAnswersAFoldWithItself(t *testing.T) {
	s := fixture()
	if s.SectionOf("settled") != "settled" || s.SectionOf("bbb") != "active" || s.SectionOf("nope") != "" {
		t.Fatal("section_of mismatch")
	}
}

func TestAge(t *testing.T) {
	cases := map[int64]string{-3: "0s", 45: "45s", 720: "12m", 10800: "3h", 172800: "2d"}
	for in, want := range cases {
		if got := age(in); got != want {
			t.Errorf("age(%d) = %q want %q", in, got, want)
		}
	}
}
