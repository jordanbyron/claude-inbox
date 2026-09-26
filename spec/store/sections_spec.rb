# frozen_string_literal: true

Store = ClaudeInbox::Store unless defined?(Store)

RSpec.describe ClaudeInbox::Store::Sections do
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
    expect(sec.row(row("a")).id).to eq("a")
    expect(sec.row(row("uuid")).session.session_id).to eq("uuid")
    expect(sec.row(row("nope"))).to be_nil
    expect(sec.row(fold(:settled))).to be_nil
    expect(sec.row(nil)).to be_nil
  end

  it "lists where the cursor can land, a fold standing in for its rows" do
    expect(sec.selections({})).to eq([row("b"), row("a"), row("uuid"), row("c"), fold(:settled)])
    expect(sec.selections({settled: true})).to eq(%w[b a uuid c z].map { |k| row(k) })
  end

  it "leaves an empty fold out of the landable selections" do
    expect(sections([session(id: "a")]).selections({})).to eq([row("a")])
  end

  it "skips rows with no key" do
    keyless = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: nil)
    expect(sections([keyless, session(id: "a")]).selections({})).to eq([row("a")])
  end

  it "names the section a selection lives in, and a fold answers itself" do
    expect(sec.section_of(row("b"))).to eq(:pinned)
    expect(sec.section_of(row("a"))).to eq(:needs_you)
    expect(sec.section_of(row("uuid"))).to eq(:active)
    expect(sec.section_of(row("z"))).to eq(:settled)
    expect(sec.section_of(fold(:snoozed))).to eq(:snoozed)
    expect(sec.section_of(row("nope"))).to be_nil
    expect(sec.section_of(nil)).to be_nil
  end

  it "heads each section with its fold, or its first selectable row" do
    heads = sec.heads({})
    expect(heads.map(&:first)).to eq(%i[pinned needs_you active settled])
    expect(heads.map(&:last)).to eq([row("b"), row("a"), row("uuid"), fold(:settled)])
    expect(sec.heads({settled: true}).map(&:last)).to eq(%w[b a uuid z].map { |k| row(k) })
  end

  it "filters by label or cwd, case-insensitively, and keeps rows in their sections" do
    expect(sec.matching("OTHER").active.map(&:key)).to eq(%w[c])
    expect(sec.matching("/tmp/term").active.map(&:key)).to eq(%w[uuid])
    expect(sec.matching("thing").all.map(&:key)).to eq(%w[b a uuid z])
    expect(sec.matching("zzz").all).to be_empty
    expect(sec.matching("")).to equal(sec)
    expect(sec.matching(nil)).to equal(sec)
  end
end
