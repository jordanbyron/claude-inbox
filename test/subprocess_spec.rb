# frozen_string_literal: true

require_relative "test_helper"

describe ClaudeInbox::Subprocess do
  it "captures a child's output and exit status" do
    r = ClaudeInbox::Subprocess.capture("sh", "-c", "echo out; echo err >&2; exit 3")
    _(r.out).must_equal "out\n"
    _(r.err).must_equal "err\n"
    _(r.status.exitstatus).must_equal 3
  end

  it "starts children without our Bundler environment" do
    saved = ENV.to_h.slice("BUNDLE_GEMFILE", "RUBYOPT")
    ENV["BUNDLE_GEMFILE"] = "/sentinel/Gemfile"
    ENV["RUBYOPT"] = "-r/sentinel/bundler/setup"
    r = ClaudeInbox::Subprocess.capture("env")
    _(r.out.lines.grep(/sentinel/)).must_be_empty
  ensure
    %w[BUNDLE_GEMFILE RUBYOPT].each { |k| ENV[k] = saved[k] }
  end

  it "keeps the rest of the environment" do
    r = ClaudeInbox::Subprocess.capture("env")
    _(r.out).must_match(/^HOME=#{Regexp.escape(Dir.home)}$/)
    _(r.out).must_match(/^PATH=/)
  end
end
