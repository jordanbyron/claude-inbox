# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::StackLinks do
  let(:links) { described_class.new }
  let(:submit) {
    ->(*numbers) {
      stdout = ["Pushing to origin...", *numbers.map { |n| "✓ Created PR ##{n} (https://github.com/o/r/pull/#{n}) for b#{n}" }].join("\n")
      JSON.generate("type" => "user", "toolUseResult" => {"stdout" => stdout}) + "\n"
    }
  }

  it "finds every PR gh stack submit created, in order, across submits" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.jsonl")
      File.write(path, submit.call(341, 342) + JSON.generate("type" => "assistant") + "\n")
      expect(links.urls(path)).to eq(%w[https://github.com/o/r/pull/341 https://github.com/o/r/pull/342])

      File.write(path, submit.call(344), mode: "a")
      expect(links.urls(path).last).to eq("https://github.com/o/r/pull/344")
      expect(links.urls(path).size).to eq(3)
    end
  end

  it "ignores a PR only quoted, and a line still being written" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.jsonl")
      quoted = JSON.generate("type" => "user", "toolUseResult" => {"stdout" => "420 :: ✓ Created PR #9 (https://github.com/o/r/pull/9)"})
      said = JSON.generate("type" => "assistant", "message" => "✓ Created PR #8 (https://github.com/o/r/pull/8)")
      File.write(path, [quoted, said].join("\n") + "\n" + submit.call(7).chomp)
      expect(links.urls(path)).to eq([])

      File.write(path, "\n", mode: "a")
      expect(links.urls(path)).to eq(["https://github.com/o/r/pull/7"])
    end
  end

  it "starts over when the transcript shrinks, and is empty without one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.jsonl")
      File.write(path, submit.call(1, 2))
      links.urls(path)
      File.write(path, submit.call(3))
      expect(links.urls(path)).to eq(["https://github.com/o/r/pull/3"])
      expect(links.urls(File.join(dir, "gone.jsonl"))).to eq([])
      expect(links.urls(nil)).to eq([])
    end
  end
end
