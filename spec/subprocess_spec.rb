# frozen_string_literal: true

RSpec.describe ClaudeInbox::Subprocess do
  it "captures a child's output and exit status" do
    r = described_class.capture("sh", "-c", "echo out; echo err >&2; exit 3")
    expect(r.out).to eq("out\n")
    expect(r.err).to eq("err\n")
    expect(r.status.exitstatus).to eq(3)
  end

  it "feeds input to the child's stdin" do
    expect(described_class.capture("cat", input: "hi").out).to eq("hi")
  end

  it "survives a child that exits without reading its input" do
    expect(described_class.capture("true", input: "hi").status.exitstatus).to eq(0)
  end

  it "starts children without our Bundler environment" do
    saved = ENV.to_h.slice("BUNDLE_GEMFILE", "RUBYOPT")
    ENV["BUNDLE_GEMFILE"] = "/sentinel/Gemfile"
    ENV["RUBYOPT"] = "-r/sentinel/bundler/setup"
    r = described_class.capture("env")
    expect(r.out.lines.grep(/sentinel/)).to be_empty
  ensure
    %w[BUNDLE_GEMFILE RUBYOPT].each { |k| ENV[k] = saved[k] }
  end

  it "takes the ruby asdf pinned to run us off the PATH a child gets" do
    env = {
      "ASDF_INSTALL_PATH" => "/asdf/installs/ruby/3.4.9",
      "ASDF_INSTALL_VERSION" => "3.4.9",
      "ASDF_DATA_DIR" => "/asdf",
      "PATH" => "/asdf/installs/ruby/3.4.9/bin:/asdf/installs/ruby/3.4.9/lib/ruby/gems/.0/bin:/asdf/shims:/usr/bin"
    }
    expect(described_class.unpinned(env)).to eq("ASDF_DATA_DIR" => "/asdf", "PATH" => "/asdf/shims:/usr/bin")
  end

  it "leaves PATH alone when asdf did not start us" do
    env = {"PATH" => "/usr/local/bin:/usr/bin"}
    expect(described_class.unpinned(env)).to eq(env)
  end

  it "keeps the rest of the environment" do
    r = described_class.capture("env")
    expect(r.out).to match(/^HOME=#{Regexp.escape(Dir.home)}$/)
    expect(r.out).to match(/^PATH=/)
  end
end
