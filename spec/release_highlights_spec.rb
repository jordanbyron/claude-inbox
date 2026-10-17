# frozen_string_literal: true

require_relative "../release/highlights"
require_relative "../release/pull_request"

RSpec.describe Release::Highlights do
  let(:picker) { Release::PullRequest.new(number: 12, title: "feat: pick a pull request", body: "Adds a picker.\n", labels: []) }
  let(:snooze) { Release::PullRequest.new(number: 14, title: "feat: snooze for a typed time", body: "Adds `5`.", labels: []) }

  it "asks for a Highlights section for the release" do
    prompt = described_class.new("v0.11.0", {picker => nil}).prompt
    expect(prompt).to include("claude-inbox v0.11.0")
    expect(prompt).to include("starting with the line `## Highlights`")
  end

  it "lists each pull request with its description and screenshot" do
    prompt = described_class.new("v0.11.0", {picker => "https://example.com/picker.png", snooze => nil}).prompt
    expect(prompt).to include("--- #12 feat: pick a pull request\nScreenshot: https://example.com/picker.png\n\nAdds a picker.")
    expect(prompt).to include("--- #14 feat: snooze for a typed time\nScreenshot: none\n\nAdds `5`.")
  end
end
