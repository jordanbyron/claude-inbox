# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"
require_relative "../lib/claude_inbox/rate_limits"

describe ClaudeInbox::RateLimits do
  let(:now) { Time.now }

  def window(span, percent, resets_at = nil) = ClaudeInbox::RateLimits::Window.new(span, percent, resets_at)

  def with_file(json)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rate_limits.json")
      File.write(path, json) if json
      yield ClaudeInbox::RateLimits.new(path: path), path
    end
  end

  it "shows both windows, rounded" do
    with_file('{"five_hour":{"used_percentage":23.5,"resets_at":1},"seven_day":{"used_percentage":41.2,"resets_at":2}}') do |rl|
      _(rl.windows(now)).must_equal [window("5h", 24, Time.at(1)), window("7d", 41, Time.at(2))]
    end
  end

  it "shows whichever window is present" do
    with_file('{"seven_day":{"used_percentage":80}}') { |rl| _(rl.windows(now)).must_equal [window("7d", 80)] }
  end

  it "is nil with no file, an empty object, or junk" do
    with_file(nil) { |rl| _(rl.windows(now)).must_be_nil }
    with_file("{}") { |rl| _(rl.windows(now)).must_be_nil }
    with_file("not json") { |rl| _(rl.windows(now)).must_be_nil }
    with_file("[1]") { |rl| _(rl.windows(now)).must_be_nil }
  end

  it "is nil once the file goes stale" do
    with_file('{"five_hour":{"used_percentage":10}}') do |rl|
      _(rl.windows(now)).wont_be_nil
      _(rl.windows(now + ClaudeInbox::RateLimits::STALE_AFTER + 1)).must_be_nil
    end
  end

  it "re-reads only when the file changes" do
    with_file('{"five_hour":{"used_percentage":10}}') do |rl, path|
      _(rl.windows(now)).must_equal [window("5h", 10)]
      File.write(path, '{"five_hour":{"used_percentage":50}}')
      File.utime(now + 1, now + 1, path)
      _(rl.windows(now + 2)).must_equal [window("5h", 50)]
      File.delete(path)
      _(rl.windows(now + 3)).must_be_nil
    end
  end
end
