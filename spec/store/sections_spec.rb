# frozen_string_literal: true

RSpec.describe ClaudeInbox::Store::Sections do
  subject(:sec) do
    entries = {"b" => {"pinned" => true}, "z" => {"settled_at" => now.to_i}}
    sessions = [terminal, session(id: "a", state: "blocked"), session(id: "b"), session(id: "c", name: "Other", cwd: "/srv/other"), session(id: "z", state: "done")]
    ClaudeInbox::Store.sectionize(sessions, entries, now)
  end

  let(:now) { Time.at(1_789_600_000) }
  let(:selection) { ClaudeInbox::Store::Selection }
  let(:terminal) { session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid", cwd: "/tmp/term") }

  it "finds a row by its selection, or nothing" do
    expect(sec.row(selection.row("a")).id).to eq("a")
    expect(sec.row(selection.row("uuid")).session.session_id).to eq("uuid")
    expect(sec.row(selection.row("nope"))).to be_nil
    expect(sec.row(selection.fold(:settled))).to be_nil
    expect(sec.row(nil)).to be_nil
  end

  it "lists where the cursor can land, a fold standing in for its rows" do
    expect(sec.selections({})).to eq([selection.row("b"), selection.row("a"), selection.row("uuid"), selection.row("c"), selection.fold(:settled)])
    expect(sec.selections({settled: true})).to eq(%w[b a uuid c z].map { |k| selection.row(k) })
  end

  it "leaves an empty fold out of the landable selections" do
    expect(ClaudeInbox::Store.sectionize([session(id: "a")], {}, now).selections({})).to eq([selection.row("a")])
  end

  it "skips rows with no key" do
    keyless = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: nil)
    expect(ClaudeInbox::Store.sectionize([keyless, session(id: "a")], {}, now).selections({})).to eq([selection.row("a")])
  end

  it "names the section a selection lives in, and a fold answers itself" do
    expect(sec.section_of(selection.row("b"))).to eq(:pinned)
    expect(sec.section_of(selection.row("a"))).to eq(:needs_you)
    expect(sec.section_of(selection.row("uuid"))).to eq(:active)
    expect(sec.section_of(selection.row("z"))).to eq(:settled)
    expect(sec.section_of(selection.fold(:snoozed))).to eq(:snoozed)
    expect(sec.section_of(selection.row("nope"))).to be_nil
    expect(sec.section_of(nil)).to be_nil
  end

  it "heads each section with its fold, or its first selectable row" do
    heads = sec.heads({})
    expect(heads.map(&:first)).to eq(%i[pinned needs_you active settled])
    expect(heads.map(&:last)).to eq([selection.row("b"), selection.row("a"), selection.row("uuid"), selection.fold(:settled)])
    expect(sec.heads({settled: true}).map(&:last)).to eq(%w[b a uuid z].map { |k| selection.row(k) })
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
