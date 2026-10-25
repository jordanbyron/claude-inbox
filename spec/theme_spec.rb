# frozen_string_literal: true

RSpec.describe ClaudeInbox::Theme do
  let(:theme) { described_class.new }
  let(:pr) { ->(**attrs) { ClaudeInbox::PullRequest.new(url: "https://github.com/o/r/pull/#{attrs[:number]}", **attrs) } }
  let(:linked) { ->(text, number) { ClaudeInbox::Text.link(theme.underline(text), "https://github.com/o/r/pull/#{number}") } }

  it "badges a PR in GitHub's colors, naming what is wrong with it" do
    failing = pr.call(number: 190, state: "OPEN", health: "FAILING")
    expect(theme.pr_badge(failing))
      .to eq(theme.dim("PR ") + linked.call(theme.green("#190"), 190) + theme.green(" open") + theme.dim(" · ") + theme.red("✗ checks"))
    expect(theme.pr_badge(pr.call(number: 7, state: "MERGED"), "o/r#7"))
      .to eq(theme.dim("PR ") + linked.call(theme.purple("o/r#7"), 7) + theme.purple(" merged"))
    expect(theme.pr_badge(pr.call(number: 8, state: "DRAFT"))).to eq(theme.dim("PR ") + linked.call(theme.dim("#8"), 8) + theme.dim(" draft"))
    expect(theme.pr_badge(pr.call(number: 9))).to eq(theme.dim("PR ") + linked.call(theme.dim("#9"), 9))
  end

  it "dims a quiet badge and leaves out what is wrong with it" do
    badge = theme.pr_badge(pr.call(number: 190, state: "OPEN", health: "FAILING"), quiet: true)
    expect(badge).to eq(theme.dim("PR ") + linked.call(theme.dim("#190"), 190) + theme.dim(" open"))
  end
end
