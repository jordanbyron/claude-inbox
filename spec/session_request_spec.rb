# frozen_string_literal: true

require_relative "../lib/claude_inbox/new_session_form"
require_relative "../lib/claude_inbox/session_request"
require "tmpdir"

RSpec.describe ClaudeInbox::SessionRequest do
  let(:base) { {"prompt" => "go", "cwd" => "/tmp"} }

  def from(params, dirs: []) = ClaudeInbox::SessionRequest.from_params(params, dirs: dirs)

  # [field, message] of the Invalid the params raise.
  def refusal(params, dirs: [])
    error = nil
    expect { from(params, dirs: dirs) }.to raise_error(ClaudeInbox::SessionRequest::Invalid) { |e| error = e }
    [error.field, error.message]
  end

  describe "from_params" do
    it "builds the same hash the form's values do, once resolved against the same settings" do
      # An empty home, so the developer's own ~/.claude settings stay out of the form's defaults.
      Dir.mktmpdir do |home|
        form = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
        values = from({"prompt" => "", "cwd" => Dir.pwd})
        expect(ClaudeInbox::SessionRequest.resolve(values, form.defaults)).to eq(form.values)
      end
    end

    it "leaves a setting sent as default unset, the same as one left out" do
      sent = base.merge("model" => "default", "effort" => "default", "permission_mode" => "default")
      expect(from(sent)).to eq(from(base))
      expect(from(base).values_at(:model, :effort, :permission_mode, :remote)).to eq([nil, nil, nil, nil])
    end

    it "takes every setting the form has, by string or symbol key" do
      v = from({:prompt => "go", :name => "flaky", :cwd => "/tmp", :model => "opus", "effort" => "high",
        "permission_mode" => "plan", "worktree" => true, "remote" => "yes"})
      expect(v).to eq({prompt: "go", name: "flaky", cwd: "/tmp", model: "opus", effort: "high",
        permission_mode: "plan", worktree: true, remote: true})
    end

    it "refuses an unknown key rather than dropping it" do
      expect(refusal(base.merge("permissions" => "plan"))).to eq([:permissions, "unknown key: \"permissions\""])
    end

    it "quotes an unknown key, escapes and all, so its message prints as plain text" do
      expect(refusal(base.merge("\e[31mkey" => 1)).last).to eq("unknown key: \"\\e[31mkey\"")
    end

    it "strips the prompt and keeps it to at most 100,000 characters" do
      expect(from(base.merge("prompt" => "  fix the flaky spec \n"))[:prompt]).to eq("fix the flaky spec")
      expect(from(base.merge("prompt" => "x" * 100_000))[:prompt].size).to eq(100_000)
      expect(refusal(base.merge("prompt" => "x" * 100_001))).to eq([:prompt, "the prompt is over 100000 characters"])
    end

    it "keeps tabs and newlines in the prompt, CRLF as a newline, and no other control character" do
      expect(from(base.merge("prompt" => "one\r\n\ttwo\rthree"))[:prompt]).to eq("one\n\ttwo\nthree")
      ["a\e[2Jb", "a\ab", "a\u0085b", "a\x7Fb"].each do |prompt|
        expect(refusal(base.merge("prompt" => prompt)))
          .to eq([:prompt, "the prompt has a control character other than tab or newline"])
      end
    end

    it "leaves a missing prompt blank, for problem to report as the form does" do
      expect(from({"cwd" => "/tmp"})[:prompt]).to eq("")
    end

    it "refuses text that is not a string, not UTF-8 or carries a NUL byte" do
      expect(refusal(base.merge("prompt" => 42))).to eq([:prompt, "prompt must be a string"])
      expect(refusal(base.merge("prompt" => "\xFF"))).to eq([:prompt, "prompt is not valid UTF-8"])
      expect(refusal(base.merge("prompt" => "\xFF".b))).to eq([:prompt, "prompt is not valid UTF-8"])
      expect(from(base.merge("prompt" => "caf\xC3\xA9".b))[:prompt]).to eq("café")
      expect(refusal(base.merge("prompt" => "a\0b"))).to eq([:prompt, "prompt contains a NUL byte"])
      expect(refusal(base.merge("cwd" => "/tmp\0"))).to eq([:cwd, "cwd contains a NUL byte"])
      expect(refusal(base.merge("name" => ["x"]))).to eq([:name, "name must be a string"])
    end

    it "takes a name of one line, at most 100 characters and no control character, blank as none" do
      expect(from(base.merge("name" => "  flaky \n"))[:name]).to eq("flaky")
      expect(from(base.merge("name" => "  "))[:name]).to be_nil
      expect(from(base.merge("name" => nil))[:name]).to be_nil
      expect(from(base.merge("name" => "fix \u{1F468}\u200D\u{1F469}"))[:name]).to eq("fix \u{1F468}\u200D\u{1F469}")
      ["two\nlines", "a\e[2Jb", "a\tb", "a\u0085b", "a\u2028b", "a\u2029b"].each do |name|
        expect(refusal(base.merge("name" => name))).to eq([:name, "a name is one line"])
      end
      expect(refusal(base.merge("name" => "n" * 101))).to eq([:name, "the name is over 100 characters"])
    end

    it "takes a directory as an absolute or ~ path, expanded" do
      expect(from(base.merge("cwd" => "/tmp/../tmp/"))[:cwd]).to eq("/tmp")
      expect(from(base.merge("cwd" => "~"))[:cwd]).to eq(Dir.home)
      expect(from(base.merge("cwd" => "~/code"))[:cwd]).to eq(File.join(Dir.home, "code"))
      expect(refusal(base.merge("cwd" => "  "))).to eq([:cwd, "a directory is required"])
      expect(refusal({"prompt" => "go"})).to eq([:cwd, "a directory is required"])
    end

    it "refuses a directory with a control character in it" do
      ["/tmp/\e]0;x\a", "/tmp/a\nb", "app\e[2J", "/tmp/a\u2028b"].each do |cwd|
        expect(refusal(base.merge("cwd" => cwd))).to eq([:cwd, "a directory is one line"])
      end
    end

    it "takes a directory by the label it was offered under, when only one fits" do
      dirs = ["/Users/me/code/app", "/Users/me/work/app", "/Users/me/code/claude-inbox"]
      expect(from(base.merge("cwd" => "claude-inbox"), dirs: dirs)[:cwd]).to eq("/Users/me/code/claude-inbox")
      expect(from(base.merge("cwd" => "work/app"), dirs: dirs)[:cwd]).to eq("/Users/me/work/app")
      expect(refusal(base.merge("cwd" => "app"), dirs: dirs))
        .to eq([:cwd, "app could be any of /Users/me/code/app, /Users/me/work/app"])
      expect(refusal(base.merge("cwd" => "inbox"), dirs: dirs)).to eq([:cwd, "no directory called inbox"])
      expect(refusal(base.merge("cwd" => "~me/code"), dirs: dirs)).to eq([:cwd, "no directory called ~me/code"])
    end

    it "takes model, effort and permissions from the choices the form offers" do
      (ClaudeInbox::AgentsClient::PERMISSION_MODES - ["default"]).each do |mode|
        expect(from(base.merge("permission_mode" => mode))[:permission_mode]).to eq(mode)
      end
      expect(from(base.merge("model" => "haiku", "effort" => "max"))).to eq(
        from(base).merge(model: "haiku", effort: "max")
      )
      expect(refusal(base.merge("model" => "gpt"))).to eq([:model, "model is one of default, fable, opus, sonnet, haiku"])
      expect(refusal(base.merge("effort" => 3)).first).to eq(:effort)
      expect(refusal(base.merge("permission_mode" => "yolo")).first).to eq(:permission_mode)
    end

    it "takes worktree and remote as true or false, yes or no" do
      {true => true, false => false, "yes" => true, "no" => false}.each do |sent, taken|
        expect(from(base.merge("worktree" => sent, "remote" => sent)).values_at(:worktree, :remote)).to eq([taken, taken])
      end
      expect(from(base.merge("worktree" => nil, "remote" => nil)).values_at(:worktree, :remote)).to eq([false, nil])
      expect(refusal(base.merge("remote" => "on"))).to eq([:remote, "remote is true, false, yes or no"])
      expect(refusal(base.merge("worktree" => 1)).first).to eq(:worktree)
    end
  end

  describe "resolve" do
    let(:defaults) { ->(remote) { ClaudeInbox::Settings::Defaults.new(model: "opus", permission_mode: "plan", remote: remote) } }

    it "follows /config for Remote Control left unset, and passes it either way" do
      values = from(base)
      expect(ClaudeInbox::SessionRequest.resolve(values, defaults.call("yes"))[:remote]).to be(true)
      expect(ClaudeInbox::SessionRequest.resolve(values, defaults.call("no"))[:remote]).to be(false)
      expect(ClaudeInbox::SessionRequest.resolve(values, defaults.call(nil))[:remote]).to be(false)
      expect(ClaudeInbox::SessionRequest.resolve(values.merge(remote: false), defaults.call("yes"))[:remote]).to be(false)
    end

    it "leaves the other settings to the CLI" do
      resolved = ClaudeInbox::SessionRequest.resolve(from(base), defaults.call(nil))
      expect(resolved.values_at(:model, :effort, :permission_mode)).to eq([nil, nil, nil])
    end
  end

  describe "label" do
    it "names a directory by as few trailing names as tell it apart, and from_params takes it back" do
      dirs = ["/Users/me/code/app", "/Users/me/work/x/app", "/Users/me/code/claude-inbox"]
      labels = dirs.map { |dir| ClaudeInbox::SessionRequest.label(dir, dirs) }
      expect(labels).to eq(%w[code/app x/app claude-inbox])
      expect(labels.map { |label| from(base.merge("cwd" => label), dirs: dirs)[:cwd] }).to eq(dirs)
    end
  end

  describe "problem" do
    def problem(**values) = ClaudeInbox::SessionRequest.problem(values)

    it "has none when there is a prompt and the directory exists" do
      expect(problem(prompt: "go", cwd: Dir.pwd)).to be_nil
    end

    it "wants a prompt first, then a directory that exists, in the form's words" do
      expect(problem(prompt: "", cwd: "/nope/nowhere")).to eq([:prompt, "a prompt is required"])
      expect(problem(prompt: "go", cwd: "/nope/nowhere")).to eq([:cwd, "no such directory: /nope/nowhere"])
    end
  end

  describe "attach" do
    def attach(prompt, paths) = ClaudeInbox::SessionRequest.attach(prompt, paths)

    it "turns each [Image #n] into a mention of the nth path, in any case" do
      expect(attach("make it [Image #2], not [image #1]", ["/i/a.png", "/i/b c.jpg"]))
        .to eq("make it @/i/b\\ c.jpg, not @/i/a.png")
    end

    it "puts every path the prompt never points at on the end, one per line" do
      expect(attach("fix [Image #2]", %w[/i/a.png /i/b.png /i/c.png])).to eq("fix @/i/b.png\n\n@/i/a.png\n@/i/c.png")
    end

    it "leaves a token past the last image as text" do
      expect(attach("see [Image #3] and [Image #0]", ["/i/a.png"])).to eq("see [Image #3] and [Image #0]\n\n@/i/a.png")
    end

    it "leaves a prompt without images as it was" do
      expect(attach("just [Image #1]", [])).to eq("just [Image #1]")
    end
  end

  describe "strip_worktree" do
    it "moves a directory inside an agent's worktree back to the repo it was cut from" do
      strip = ClaudeInbox::SessionRequest.method(:strip_worktree)
      expect(strip.call("/code/inbox/.claude/worktrees/foo")).to eq("/code/inbox")
      expect(strip.call("/code/inbox/.claude/worktrees/foo/lib")).to eq("/code/inbox")
      expect(strip.call("/code/inbox/lib")).to eq("/code/inbox/lib")
    end
  end
end
