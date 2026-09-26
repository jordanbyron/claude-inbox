# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/new_session_form"
require_relative "../lib/claude_inbox/session_request"
require "tmpdir"

describe ClaudeInbox::SessionRequest do
  let(:base) { {"prompt" => "go", "cwd" => "/tmp"} }

  def from(params, dirs: []) = ClaudeInbox::SessionRequest.from_params(params, dirs: dirs)

  # [field, message] of the Invalid the params raise.
  def refusal(params, dirs: [])
    e = _ { from(params, dirs: dirs) }.must_raise ClaudeInbox::SessionRequest::Invalid
    [e.field, e.message]
  end

  describe "from_params" do
    it "builds the same hash the form's values do, once resolved against the same settings" do
      # An empty home, so the developer's own ~/.claude settings stay out of the form's defaults.
      Dir.mktmpdir do |home|
        form = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
        values = from({"prompt" => "", "cwd" => Dir.pwd})
        _(ClaudeInbox::SessionRequest.resolve(values, form.defaults)).must_equal form.values
      end
    end

    it "leaves a setting sent as default unset, the same as one left out" do
      sent = base.merge("model" => "default", "effort" => "default", "permission_mode" => "default")
      _(from(sent)).must_equal from(base)
      _(from(base).values_at(:model, :effort, :permission_mode, :remote)).must_equal [nil, nil, nil, nil]
    end

    it "takes every setting the form has, by string or symbol key" do
      v = from({:prompt => "go", :name => "flaky", :cwd => "/tmp", :model => "opus", "effort" => "high",
        "permission_mode" => "plan", "worktree" => true, "remote" => "yes"})
      _(v).must_equal({prompt: "go", name: "flaky", cwd: "/tmp", model: "opus", effort: "high",
        permission_mode: "plan", worktree: true, remote: true})
    end

    it "refuses an unknown key rather than dropping it" do
      _(refusal(base.merge("permissions" => "plan"))).must_equal [:permissions, "unknown key: \"permissions\""]
    end

    it "quotes an unknown key, escapes and all, so its message prints as plain text" do
      _(refusal(base.merge("\e[31mkey" => 1)).last).must_equal "unknown key: \"\\e[31mkey\""
    end

    it "strips the prompt and keeps it to at most 100,000 characters" do
      _(from(base.merge("prompt" => "  fix the flaky spec \n"))[:prompt]).must_equal "fix the flaky spec"
      _(from(base.merge("prompt" => "x" * 100_000))[:prompt].size).must_equal 100_000
      _(refusal(base.merge("prompt" => "x" * 100_001))).must_equal [:prompt, "the prompt is over 100000 characters"]
    end

    it "keeps tabs and newlines in the prompt, CRLF as a newline, and no other control character" do
      _(from(base.merge("prompt" => "one\r\n\ttwo\rthree"))[:prompt]).must_equal "one\n\ttwo\nthree"
      ["a\e[2Jb", "a\ab", "a\u0085b", "a\x7Fb"].each do |prompt|
        _(refusal(base.merge("prompt" => prompt)))
          .must_equal [:prompt, "the prompt has a control character other than tab or newline"]
      end
    end

    it "leaves a missing prompt blank, for problem to report as the form does" do
      _(from({"cwd" => "/tmp"})[:prompt]).must_equal ""
    end

    it "refuses text that is not a string, not UTF-8 or carries a NUL byte" do
      _(refusal(base.merge("prompt" => 42))).must_equal [:prompt, "prompt must be a string"]
      _(refusal(base.merge("prompt" => "\xFF"))).must_equal [:prompt, "prompt is not valid UTF-8"]
      _(refusal(base.merge("prompt" => "\xFF".b))).must_equal [:prompt, "prompt is not valid UTF-8"]
      _(from(base.merge("prompt" => "caf\xC3\xA9".b))[:prompt]).must_equal "café"
      _(refusal(base.merge("prompt" => "a\0b"))).must_equal [:prompt, "prompt contains a NUL byte"]
      _(refusal(base.merge("cwd" => "/tmp\0"))).must_equal [:cwd, "cwd contains a NUL byte"]
      _(refusal(base.merge("name" => ["x"]))).must_equal [:name, "name must be a string"]
    end

    it "takes a name of one line, at most 100 characters and no control character, blank as none" do
      _(from(base.merge("name" => "  flaky \n"))[:name]).must_equal "flaky"
      _(from(base.merge("name" => "  "))[:name]).must_be_nil
      _(from(base.merge("name" => nil))[:name]).must_be_nil
      _(from(base.merge("name" => "fix \u{1F468}\u200D\u{1F469}"))[:name]).must_equal "fix \u{1F468}\u200D\u{1F469}"
      ["two\nlines", "a\e[2Jb", "a\tb", "a\u0085b", "a\u2028b", "a\u2029b"].each do |name|
        _(refusal(base.merge("name" => name))).must_equal [:name, "a name is one line"]
      end
      _(refusal(base.merge("name" => "n" * 101))).must_equal [:name, "the name is over 100 characters"]
    end

    it "takes a directory as an absolute or ~ path, expanded" do
      _(from(base.merge("cwd" => "/tmp/../tmp/"))[:cwd]).must_equal "/tmp"
      _(from(base.merge("cwd" => "~"))[:cwd]).must_equal Dir.home
      _(from(base.merge("cwd" => "~/code"))[:cwd]).must_equal File.join(Dir.home, "code")
      _(refusal(base.merge("cwd" => "  "))).must_equal [:cwd, "a directory is required"]
      _(refusal({"prompt" => "go"})).must_equal [:cwd, "a directory is required"]
    end

    it "refuses a directory with a control character in it" do
      ["/tmp/\e]0;x\a", "/tmp/a\nb", "app\e[2J", "/tmp/a\u2028b"].each do |cwd|
        _(refusal(base.merge("cwd" => cwd))).must_equal [:cwd, "a directory is one line"]
      end
    end

    it "takes a directory by the label it was offered under, when only one fits" do
      dirs = ["/Users/me/code/app", "/Users/me/work/app", "/Users/me/code/claude-inbox"]
      _(from(base.merge("cwd" => "claude-inbox"), dirs: dirs)[:cwd]).must_equal "/Users/me/code/claude-inbox"
      _(from(base.merge("cwd" => "work/app"), dirs: dirs)[:cwd]).must_equal "/Users/me/work/app"
      _(refusal(base.merge("cwd" => "app"), dirs: dirs))
        .must_equal [:cwd, "app could be any of /Users/me/code/app, /Users/me/work/app"]
      _(refusal(base.merge("cwd" => "inbox"), dirs: dirs)).must_equal [:cwd, "no directory called inbox"]
      _(refusal(base.merge("cwd" => "~me/code"), dirs: dirs)).must_equal [:cwd, "no directory called ~me/code"]
    end

    it "takes model, effort and permissions from the choices the form offers" do
      (ClaudeInbox::AgentsClient::PERMISSION_MODES - ["default"]).each do |mode|
        _(from(base.merge("permission_mode" => mode))[:permission_mode]).must_equal mode
      end
      _(from(base.merge("model" => "haiku", "effort" => "max"))).must_equal(
        from(base).merge(model: "haiku", effort: "max")
      )
      _(refusal(base.merge("model" => "gpt"))).must_equal [:model, "model is one of default, fable, opus, sonnet, haiku"]
      _(refusal(base.merge("effort" => 3)).first).must_equal :effort
      _(refusal(base.merge("permission_mode" => "yolo")).first).must_equal :permission_mode
    end

    it "takes worktree and remote as true or false, yes or no" do
      {true => true, false => false, "yes" => true, "no" => false}.each do |sent, taken|
        _(from(base.merge("worktree" => sent, "remote" => sent)).values_at(:worktree, :remote)).must_equal [taken, taken]
      end
      _(from(base.merge("worktree" => nil, "remote" => nil)).values_at(:worktree, :remote)).must_equal [false, nil]
      _(refusal(base.merge("remote" => "on"))).must_equal [:remote, "remote is true, false, yes or no"]
      _(refusal(base.merge("worktree" => 1)).first).must_equal :worktree
    end
  end

  describe "resolve" do
    let(:defaults) { ->(remote) { ClaudeInbox::Settings::Defaults.new(model: "opus", permission_mode: "plan", remote: remote) } }

    it "follows /config for Remote Control left unset, and passes it either way" do
      values = from(base)
      _(ClaudeInbox::SessionRequest.resolve(values, defaults.call("yes"))[:remote]).must_equal true
      _(ClaudeInbox::SessionRequest.resolve(values, defaults.call("no"))[:remote]).must_equal false
      _(ClaudeInbox::SessionRequest.resolve(values, defaults.call(nil))[:remote]).must_equal false
      _(ClaudeInbox::SessionRequest.resolve(values.merge(remote: false), defaults.call("yes"))[:remote]).must_equal false
    end

    it "leaves the other settings to the CLI" do
      resolved = ClaudeInbox::SessionRequest.resolve(from(base), defaults.call(nil))
      _(resolved.values_at(:model, :effort, :permission_mode)).must_equal [nil, nil, nil]
    end
  end

  describe "label" do
    it "names a directory by as few trailing names as tell it apart, and from_params takes it back" do
      dirs = ["/Users/me/code/app", "/Users/me/work/x/app", "/Users/me/code/claude-inbox"]
      labels = dirs.map { |dir| ClaudeInbox::SessionRequest.label(dir, dirs) }
      _(labels).must_equal %w[code/app x/app claude-inbox]
      _(labels.map { |label| from(base.merge("cwd" => label), dirs: dirs)[:cwd] }).must_equal dirs
    end
  end

  describe "problem" do
    def problem(**values) = ClaudeInbox::SessionRequest.problem(values)

    it "has none when there is a prompt and the directory exists" do
      _(problem(prompt: "go", cwd: Dir.pwd)).must_be_nil
    end

    it "wants a prompt first, then a directory that exists, in the form's words" do
      _(problem(prompt: "", cwd: "/nope/nowhere")).must_equal [:prompt, "a prompt is required"]
      _(problem(prompt: "go", cwd: "/nope/nowhere")).must_equal [:cwd, "no such directory: /nope/nowhere"]
    end
  end

  describe "attach" do
    def attach(prompt, paths) = ClaudeInbox::SessionRequest.attach(prompt, paths)

    it "turns each [Image #n] into a mention of the nth path, in any case" do
      _(attach("make it [Image #2], not [image #1]", ["/i/a.png", "/i/b c.jpg"]))
        .must_equal "make it @/i/b\\ c.jpg, not @/i/a.png"
    end

    it "puts every path the prompt never points at on the end, one per line" do
      _(attach("fix [Image #2]", %w[/i/a.png /i/b.png /i/c.png])).must_equal "fix @/i/b.png\n\n@/i/a.png\n@/i/c.png"
    end

    it "leaves a token past the last image as text" do
      _(attach("see [Image #3] and [Image #0]", ["/i/a.png"])).must_equal "see [Image #3] and [Image #0]\n\n@/i/a.png"
    end

    it "leaves a prompt without images as it was" do
      _(attach("just [Image #1]", [])).must_equal "just [Image #1]"
    end
  end

  describe "strip_worktree" do
    it "moves a directory inside an agent's worktree back to the repo it was cut from" do
      strip = ClaudeInbox::SessionRequest.method(:strip_worktree)
      _(strip.call("/code/inbox/.claude/worktrees/foo")).must_equal "/code/inbox"
      _(strip.call("/code/inbox/.claude/worktrees/foo/lib")).must_equal "/code/inbox"
      _(strip.call("/code/inbox/lib")).must_equal "/code/inbox/lib"
    end
  end
end
