# frozen_string_literal: true

require_relative "../test_helper"

Store = ClaudeInbox::Store unless defined?(Store)

describe ClaudeInbox::Store::Sections do
  let(:now) { Time.at(1_789_600_000) }

  def sections(sessions, entries = {}, at = now) = Store.sectionize(sessions, entries, at)

  let(:terminal) { session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid", cwd: "/tmp/term") }
  let(:sec) do
    entries = {"b" => {"pinned" => true}, "z" => {"settled_at" => now.to_i}}
    sections([terminal, session(id: "a", state: "blocked"), session(id: "b"), session(id: "c", name: "Other", cwd: "/srv/other"), session(id: "z", state: "done")], entries)
  end

  def row(key) = Store::Selection.row(key)

  def fold(name) = Store::Selection.fold(name)

  it "finds a row by its selection, or nothing" do
    _(sec.row(row("a")).id).must_equal "a"
    _(sec.row(row("uuid")).session.session_id).must_equal "uuid"
    _(sec.row(row("nope"))).must_be_nil
    _(sec.row(fold(:settled))).must_be_nil
    _(sec.row(nil)).must_be_nil
  end

  it "lists where the cursor can land, a fold standing in for its rows" do
    _(sec.selections({})).must_equal [row("b"), row("a"), row("uuid"), row("c"), fold(:settled)]
    _(sec.selections({settled: true})).must_equal %w[b a uuid c z].map { |k| row(k) }
  end

  it "leaves an empty fold out of the landable selections" do
    _(sections([session(id: "a")]).selections({})).must_equal [row("a")]
  end

  it "skips rows with no key" do
    keyless = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: nil)
    _(sections([keyless, session(id: "a")]).selections({})).must_equal [row("a")]
  end

  it "names the section a selection lives in, and a fold answers itself" do
    _(sec.section_of(row("b"))).must_equal :pinned
    _(sec.section_of(row("a"))).must_equal :needs_you
    _(sec.section_of(row("uuid"))).must_equal :active
    _(sec.section_of(row("z"))).must_equal :settled
    _(sec.section_of(fold(:snoozed))).must_equal :snoozed
    _(sec.section_of(row("nope"))).must_be_nil
    _(sec.section_of(nil)).must_be_nil
  end

  it "heads each section with its fold, or its first selectable row" do
    heads = sec.heads({})
    _(heads.map(&:first)).must_equal %i[pinned needs_you active settled]
    _(heads.map(&:last)).must_equal [row("b"), row("a"), row("uuid"), fold(:settled)]
    _(sec.heads({settled: true}).map(&:last)).must_equal %w[b a uuid z].map { |k| row(k) }
  end

  it "filters by label or cwd, case-insensitively, and keeps rows in their sections" do
    _(sec.matching("OTHER").active.map(&:key)).must_equal %w[c]
    _(sec.matching("/tmp/term").active.map(&:key)).must_equal %w[uuid]
    _(sec.matching("thing").all.map(&:key)).must_equal %w[b a uuid z]
    _(sec.matching("zzz").all).must_be_empty
    _(sec.matching("")).must_be_same_as sec
    _(sec.matching(nil)).must_be_same_as sec
  end
end
