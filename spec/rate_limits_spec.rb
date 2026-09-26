# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::RateLimits do
  let(:now) { Time.now }
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "rate_limits.json") }
  let(:rl) { described_class.new(path: path) }

  after { FileUtils.remove_entry(dir) }

  it "shows both windows, rounded" do
    File.write(path, '{"five_hour":{"used_percentage":23.5,"resets_at":1},"seven_day":{"used_percentage":41.2,"resets_at":2}}')
    expect(rl.windows(now)).to eq([
      described_class::Window.new("session", 24, Time.at(1)), described_class::Window.new("week", 41, Time.at(2))
    ])
  end

  it "shows whichever window is present" do
    File.write(path, '{"seven_day":{"used_percentage":80}}')
    expect(rl.windows(now)).to eq([described_class::Window.new("week", 80, nil)])
  end

  it "is nil with no file, an empty object, or junk" do
    expect(rl.windows(now)).to be_nil
    ["{}", "not json", "[1]"].each do |json|
      File.write(path, json)
      expect(described_class.new(path: path).windows(now)).to be_nil
    end
  end

  it "is nil once the file goes stale" do
    File.write(path, '{"five_hour":{"used_percentage":10}}')
    expect(rl.windows(now)).not_to be_nil
    expect(rl.windows(now + described_class::STALE_AFTER + 1)).to be_nil
  end

  it "re-reads only when the file changes" do
    File.write(path, '{"five_hour":{"used_percentage":10}}')
    expect(rl.windows(now)).to eq([described_class::Window.new("session", 10, nil)])
    File.write(path, '{"five_hour":{"used_percentage":50}}')
    File.utime(now + 1, now + 1, path)
    expect(rl.windows(now + 2)).to eq([described_class::Window.new("session", 50, nil)])
    File.delete(path)
    expect(rl.windows(now + 3)).to be_nil
  end
end
