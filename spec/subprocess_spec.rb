# frozen_string_literal: true

RSpec.describe ClaudeInbox::Subprocess do
  it "captures a child's output and exit status" do
    r = ClaudeInbox::Subprocess.capture("sh", "-c", "echo out; echo err >&2; exit 3")
    expect(r.out).to eq("out\n")
    expect(r.err).to eq("err\n")
    expect(r.status.exitstatus).to eq(3)
  end

  it "starts children without our Bundler environment" do
    saved = ENV.to_h.slice("BUNDLE_GEMFILE", "RUBYOPT")
    ENV["BUNDLE_GEMFILE"] = "/sentinel/Gemfile"
    ENV["RUBYOPT"] = "-r/sentinel/bundler/setup"
    r = ClaudeInbox::Subprocess.capture("env")
    expect(r.out.lines.grep(/sentinel/)).to be_empty
  ensure
    %w[BUNDLE_GEMFILE RUBYOPT].each { |k| ENV[k] = saved[k] }
  end

  it "keeps the rest of the environment" do
    r = ClaudeInbox::Subprocess.capture("env")
    expect(r.out).to match(/^HOME=#{Regexp.escape(Dir.home)}$/)
    expect(r.out).to match(/^PATH=/)
  end
end
