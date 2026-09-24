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
    _(ENV["RUBYOPT"]).must_match(/bundler/)
    r = ClaudeInbox::Subprocess.capture("env")
    _(r.out.lines.grep(/^(BUNDLE_GEMFILE|RUBYOPT)=/).grep(/bundler|Gemfile/)).must_be_empty
  end

  it "keeps the rest of the environment" do
    r = ClaudeInbox::Subprocess.capture("env")
    _(r.out).must_match(/^HOME=#{Regexp.escape(Dir.home)}$/)
    _(r.out).must_match(/^PATH=/)
  end
end
