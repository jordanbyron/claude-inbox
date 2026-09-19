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

  it "finds a row by key, or nothing" do
    _(sec.row("a").id).must_equal "a"
    _(sec.row("uuid").session.session_id).must_equal "uuid"
    _(sec.row("nope")).must_be_nil
    _(sec.row(:settled)).must_be_nil
  end

  it "lists the keys the cursor can land on, a fold standing in for its rows" do
    _(sec.selectable_keys({})).must_equal ["b", "a", "uuid", "c", :settled]
    _(sec.selectable_keys({settled: true})).must_equal %w[b a uuid c z]
  end

  it "leaves an empty fold out of the landable keys" do
    _(sections([session(id: "a")]).selectable_keys({})).must_equal %w[a]
  end

  it "skips rows with no key" do
    keyless = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: nil)
    _(sections([keyless, session(id: "a")]).selectable_keys({})).must_equal %w[a]
  end

  it "names the section a key lives in, and a fold answers itself" do
    _(sec.section_of("b")).must_equal :pinned
    _(sec.section_of("a")).must_equal :needs_you
    _(sec.section_of("uuid")).must_equal :active
    _(sec.section_of("z")).must_equal :settled
    _(sec.section_of(:snoozed)).must_equal :snoozed
    _(sec.section_of("nope")).must_be_nil
  end

  it "heads each section with its fold, or its first selectable row" do
    heads = sec.heads({})
    _(heads.map(&:first)).must_equal %i[pinned needs_you active settled]
    _(heads.map { |_, row| row&.key }).must_equal ["b", "a", "uuid", nil]
    _(sec.heads({settled: true}).map { |_, row| row&.key }).must_equal %w[b a uuid z]
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
