# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ClaudeInbox::RateLimits do
  subject(:rate_limits) { described_class.new(path: path) }

  let(:now) { Time.now }
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "rate_limits.json") }

  before { File.write(path, json) if json }

  after { FileUtils.rm_rf(dir) }

  context "with both windows" do
    let(:json) { '{"five_hour":{"used_percentage":23.5,"resets_at":1},"seven_day":{"used_percentage":41.2,"resets_at":2}}' }

    it "shows both windows, rounded" do
      expect(rate_limits.windows(now)).to eq([
        described_class::Window.new("session", 24, Time.at(1)),
        described_class::Window.new("week", 41, Time.at(2))
      ])
    end
  end

  context "with only the week" do
    let(:json) { '{"seven_day":{"used_percentage":80}}' }

    it "shows whichever window is present" do
      expect(rate_limits.windows(now)).to eq([described_class::Window.new("week", 80, nil)])
    end
  end

  [nil, "{}", "not json", "[1]"].each do |contents|
    context "with #{contents ? "a file holding #{contents}" : "no file"}" do
      let(:json) { contents }

      it("is nil") { expect(rate_limits.windows(now)).to be_nil }
    end
  end

  context "with the session window" do
    let(:json) { '{"five_hour":{"used_percentage":10}}' }

    it "is nil once the file goes stale" do
      expect(rate_limits.windows(now)).not_to be_nil
      expect(rate_limits.windows(now + described_class::STALE_AFTER + 1)).to be_nil
    end

    it "re-reads only when the file changes" do
      expect(rate_limits.windows(now)).to eq([described_class::Window.new("session", 10, nil)])
      File.write(path, '{"five_hour":{"used_percentage":50}}')
      File.utime(now + 1, now + 1, path)
      expect(rate_limits.windows(now + 2)).to eq([described_class::Window.new("session", 50, nil)])
      File.delete(path)
      expect(rate_limits.windows(now + 3)).to be_nil
    end
  end
end
