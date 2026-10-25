# frozen_string_literal: true

RSpec.describe ClaudeInbox::Theme do
  let(:theme) { described_class.new }

  it "badges a PR in GitHub's colors, naming what is wrong with it" do
    failing = ClaudeInbox::PullRequest.new(number: 190, state: "OPEN", health: "FAILING")
    expect(theme.pr_badge(failing)).to eq(theme.green("PR #190 open") + theme.dim(" · ") + theme.red("✗ checks"))
    expect(theme.pr_badge(ClaudeInbox::PullRequest.new(number: 7, state: "MERGED"), "o/r#7")).to eq(theme.purple("o/r#7 merged"))
    expect(theme.pr_badge(ClaudeInbox::PullRequest.new(number: 8, state: "DRAFT"))).to eq(theme.dim("PR #8 draft"))
    expect(theme.pr_badge(ClaudeInbox::PullRequest.new(number: 9))).to eq(theme.dim("PR #9"))
  end
end
