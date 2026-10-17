# frozen_string_literal: true

require_relative "../release/pull_request"

RSpec.describe Release::PullRequest do
  let(:json) { '{"number":12,"title":"feat: add a key","body":"Adds a key.","labels":[{"name":"ai-generated"}]}' }

  it "finds the pull request numbers in the commit messages since the last tag" do
    messages = ["feat: add a key (#12)\n\nBody.", "\nchore: release v0.3.0\n", "\nfix: stop crashing (#14)\n"]
    expect(described_class.numbers_in(messages)).to eq(%w[12 14])
  end

  it "parses what gh pr view --json prints" do
    pull_request = described_class.parse(json)
    expect(pull_request.number).to eq(12)
    expect(pull_request.title).to eq("feat: add a key")
    expect(pull_request.body).to eq("Adds a key.")
    expect(pull_request.labels).to eq(["ai-generated"])
  end

  it "names the label the prefix calls for when the pull request has no type label" do
    expect(described_class.parse(json).missing_label).to eq("enhancement")
    fix = described_class.new(number: 1, title: "fix(ui): keep the cursor", body: "", labels: [])
    expect(fix.missing_label).to eq("bug")
  end

  it "leaves a pull request alone once it carries any type label" do
    labeled = described_class.new(number: 1, title: "feat: add a key", body: "", labels: %w[ai-generated bug])
    expect(labeled.missing_label).to be_nil
  end

  it "has no label for a prefix the notes do not group" do
    chore = described_class.new(number: 1, title: "chore: bump deps", body: "", labels: [])
    expect(chore.missing_label).to be_nil
  end
end
