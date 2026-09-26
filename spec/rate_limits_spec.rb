# frozen_string_literal: true

RSpec.describe ClaudeInbox::RateLimits, :rate_limits do
  let(:now) { Time.now }

  it "shows both windows, rounded" do
    with_file('{"five_hour":{"used_percentage":23.5,"resets_at":1},"seven_day":{"used_percentage":41.2,"resets_at":2}}') do |rl|
      expect(rl.windows(now)).to eq([window("session", 24, Time.at(1)), window("week", 41, Time.at(2))])
    end
  end

  it "shows whichever window is present" do
    with_file('{"seven_day":{"used_percentage":80}}') { |rl| expect(rl.windows(now)).to eq([window("week", 80)]) }
  end

  it "is nil with no file, an empty object, or junk" do
    with_file(nil) { |rl| expect(rl.windows(now)).to be_nil }
    with_file("{}") { |rl| expect(rl.windows(now)).to be_nil }
    with_file("not json") { |rl| expect(rl.windows(now)).to be_nil }
    with_file("[1]") { |rl| expect(rl.windows(now)).to be_nil }
  end

  it "is nil once the file goes stale" do
    with_file('{"five_hour":{"used_percentage":10}}') do |rl|
      expect(rl.windows(now)).not_to be_nil
      expect(rl.windows(now + described_class::STALE_AFTER + 1)).to be_nil
    end
  end

  it "re-reads only when the file changes" do
    with_file('{"five_hour":{"used_percentage":10}}') do |rl, path|
      expect(rl.windows(now)).to eq([window("session", 10)])
      File.write(path, '{"five_hour":{"used_percentage":50}}')
      File.utime(now + 1, now + 1, path)
      expect(rl.windows(now + 2)).to eq([window("session", 50)])
      File.delete(path)
      expect(rl.windows(now + 3)).to be_nil
    end
  end
end
