# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::SessionRequest do
  let(:base) { {"prompt" => "go", "cwd" => "/tmp"} }

  describe "from_params" do
    it "builds the same hash the form's values do, once resolved against the same settings" do
      # An empty home, so the developer's own ~/.claude settings stay out of the form's defaults.
      Dir.mktmpdir do |home|
        form = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
        values = described_class.from_params({"prompt" => "", "cwd" => Dir.pwd})
        expect(described_class.resolve(values, form.defaults)).to eq(form.values)
      end
    end

    it "leaves a setting sent as default unset, the same as one left out" do
      sent = base.merge("model" => "default", "effort" => "default", "permission_mode" => "default")
      expect(described_class.from_params(sent)).to eq(described_class.from_params(base))
      expect(described_class.from_params(base).values_at(:model, :effort, :permission_mode, :remote))
        .to eq([nil, nil, nil, nil])
    end

    it "takes every setting the form has, by string or symbol key" do
      v = described_class.from_params({:prompt => "go", :name => "flaky", :cwd => "/tmp", :model => "opus",
        "effort" => "high", "permission_mode" => "plan", "worktree" => true, "remote" => "yes"})
      expect(v).to eq({prompt: "go", name: "flaky", cwd: "/tmp", model: "opus", effort: "high",
        permission_mode: "plan", worktree: true, remote: true})
    end

    it "refuses an unknown key rather than dropping it" do
      expect { described_class.from_params(base.merge("permissions" => "plan")) }
        .to refuse_as(:permissions, "unknown key: \"permissions\"")
    end

    it "quotes an unknown key, escapes and all, so its message prints as plain text" do
      expect { described_class.from_params(base.merge("\e[31mkey" => 1)) }
        .to refuse_as(anything, "unknown key: \"\\e[31mkey\"")
    end

    it "strips the prompt and keeps it to at most 100,000 characters" do
      expect(described_class.from_params(base.merge("prompt" => "  fix the flaky spec \n"))[:prompt])
        .to eq("fix the flaky spec")
      expect(described_class.from_params(base.merge("prompt" => "x" * 100_000))[:prompt].size).to eq(100_000)
      expect { described_class.from_params(base.merge("prompt" => "x" * 100_001)) }
        .to refuse_as(:prompt, "the prompt is over 100000 characters")
    end

    it "keeps tabs and newlines in the prompt, CRLF as a newline, and no other control character" do
      expect(described_class.from_params(base.merge("prompt" => "one\r\n\ttwo\rthree"))[:prompt])
        .to eq("one\n\ttwo\nthree")
      ["a\e[2Jb", "a\ab", "a\u0085b", "a\x7Fb"].each do |prompt|
        expect { described_class.from_params(base.merge("prompt" => prompt)) }
          .to refuse_as(:prompt, "the prompt has a control character other than tab or newline")
      end
    end

    it "leaves a missing prompt blank, for problem to report as the form does" do
      expect(described_class.from_params({"cwd" => "/tmp"})[:prompt]).to eq("")
    end

    it "refuses text that is not a string, not UTF-8 or carries a NUL byte" do
      expect { described_class.from_params(base.merge("prompt" => 42)) }
        .to refuse_as(:prompt, "prompt must be a string")
      expect { described_class.from_params(base.merge("prompt" => "\xFF")) }
        .to refuse_as(:prompt, "prompt is not valid UTF-8")
      expect { described_class.from_params(base.merge("prompt" => "\xFF".b)) }
        .to refuse_as(:prompt, "prompt is not valid UTF-8")
      expect(described_class.from_params(base.merge("prompt" => "caf\xC3\xA9".b))[:prompt]).to eq("café")
      expect { described_class.from_params(base.merge("prompt" => "a\0b")) }
        .to refuse_as(:prompt, "prompt contains a NUL byte")
      expect { described_class.from_params(base.merge("cwd" => "/tmp\0")) }
        .to refuse_as(:cwd, "cwd contains a NUL byte")
      expect { described_class.from_params(base.merge("name" => ["x"])) }
        .to refuse_as(:name, "name must be a string")
    end

    it "takes a name of one line, at most 100 characters and no control character, blank as none" do
      expect(described_class.from_params(base.merge("name" => "  flaky \n"))[:name]).to eq("flaky")
      expect(described_class.from_params(base.merge("name" => "  "))[:name]).to be_nil
      expect(described_class.from_params(base.merge("name" => nil))[:name]).to be_nil
      expect(described_class.from_params(base.merge("name" => "fix \u{1F468}\u200D\u{1F469}"))[:name])
        .to eq("fix \u{1F468}\u200D\u{1F469}")
      ["two\nlines", "a\e[2Jb", "a\tb", "a\u0085b", "a\u2028b", "a\u2029b"].each do |name|
        expect { described_class.from_params(base.merge("name" => name)) }
          .to refuse_as(:name, "a name is one line")
      end
      expect { described_class.from_params(base.merge("name" => "n" * 101)) }
        .to refuse_as(:name, "the name is over 100 characters")
    end

    it "takes a directory as an absolute or ~ path, expanded" do
      expect(described_class.from_params(base.merge("cwd" => "/tmp/../tmp/"))[:cwd]).to eq("/tmp")
      expect(described_class.from_params(base.merge("cwd" => "~"))[:cwd]).to eq(Dir.home)
      expect(described_class.from_params(base.merge("cwd" => "~/code"))[:cwd]).to eq(File.join(Dir.home, "code"))
      expect { described_class.from_params(base.merge("cwd" => "  ")) }
        .to refuse_as(:cwd, "a directory is required")
      expect { described_class.from_params({"prompt" => "go"}) }
        .to refuse_as(:cwd, "a directory is required")
    end

    it "refuses a directory with a control character in it" do
      ["/tmp/\e]0;x\a", "/tmp/a\nb", "app\e[2J", "/tmp/a\u2028b"].each do |cwd|
        expect { described_class.from_params(base.merge("cwd" => cwd)) }
          .to refuse_as(:cwd, "a directory is one line")
      end
    end

    it "takes a directory by the label it was offered under, when only one fits" do
      dirs = ["/Users/me/code/app", "/Users/me/work/app", "/Users/me/code/claude-inbox"]
      expect(described_class.from_params(base.merge("cwd" => "claude-inbox"), dirs: dirs)[:cwd])
        .to eq("/Users/me/code/claude-inbox")
      expect(described_class.from_params(base.merge("cwd" => "work/app"), dirs: dirs)[:cwd])
        .to eq("/Users/me/work/app")
      expect { described_class.from_params(base.merge("cwd" => "app"), dirs: dirs) }
        .to refuse_as(:cwd, "app could be any of /Users/me/code/app, /Users/me/work/app")
      expect { described_class.from_params(base.merge("cwd" => "inbox"), dirs: dirs) }
        .to refuse_as(:cwd, "no directory called inbox")
      expect { described_class.from_params(base.merge("cwd" => "~me/code"), dirs: dirs) }
        .to refuse_as(:cwd, "no directory called ~me/code")
    end

    it "takes model, effort and permissions from the choices the form offers" do
      (ClaudeInbox::AgentsClient::PERMISSION_MODES - ["default"]).each do |mode|
        expect(described_class.from_params(base.merge("permission_mode" => mode))[:permission_mode]).to eq(mode)
      end
      expect(described_class.from_params(base.merge("model" => "haiku", "effort" => "max"))).to eq(
        described_class.from_params(base).merge(model: "haiku", effort: "max")
      )
      expect { described_class.from_params(base.merge("model" => "gpt")) }
        .to refuse_as(:model, "model is one of default, fable, opus, sonnet, haiku")
      expect { described_class.from_params(base.merge("effort" => 3)) }.to refuse_as(:effort)
      expect { described_class.from_params(base.merge("permission_mode" => "yolo")) }.to refuse_as(:permission_mode)
    end

    it "takes worktree and remote as true or false, yes or no" do
      {true => true, false => false, "yes" => true, "no" => false}.each do |sent, taken|
        expect(described_class.from_params(base.merge("worktree" => sent, "remote" => sent))
          .values_at(:worktree, :remote)).to eq([taken, taken])
      end
      expect(described_class.from_params(base.merge("worktree" => nil, "remote" => nil))
        .values_at(:worktree, :remote)).to eq([false, nil])
      expect { described_class.from_params(base.merge("remote" => "on")) }
        .to refuse_as(:remote, "remote is true, false, yes or no")
      expect { described_class.from_params(base.merge("worktree" => 1)) }.to refuse_as(:worktree)
    end
  end

  describe "resolve" do
    let(:defaults) { ->(remote) { ClaudeInbox::Settings::Defaults.new(model: "opus", permission_mode: "plan", remote: remote) } }

    it "follows /config for Remote Control left unset, and passes it either way" do
      values = described_class.from_params(base)
      expect(described_class.resolve(values, defaults.call("yes"))[:remote]).to be(true)
      expect(described_class.resolve(values, defaults.call("no"))[:remote]).to be(false)
      expect(described_class.resolve(values, defaults.call(nil))[:remote]).to be(false)
      expect(described_class.resolve(values.merge(remote: false), defaults.call("yes"))[:remote]).to be(false)
    end

    it "leaves the other settings to the CLI" do
      resolved = described_class.resolve(described_class.from_params(base), defaults.call(nil))
      expect(resolved.values_at(:model, :effort, :permission_mode)).to eq([nil, nil, nil])
    end
  end

  describe "label" do
    it "names a directory by as few trailing names as tell it apart, and from_params takes it back" do
      dirs = ["/Users/me/code/app", "/Users/me/work/x/app", "/Users/me/code/claude-inbox"]
      labels = dirs.map { |dir| described_class.label(dir, dirs) }
      expect(labels).to eq(%w[code/app x/app claude-inbox])
      expect(labels.map { |label| described_class.from_params(base.merge("cwd" => label), dirs: dirs)[:cwd] })
        .to eq(dirs)
    end
  end

  describe "problem" do
    it "has none when there is a prompt and the directory exists" do
      expect(described_class.problem({prompt: "go", cwd: Dir.pwd})).to be_nil
    end

    it "wants a prompt first, then a directory that exists, in the form's words" do
      expect(described_class.problem({prompt: "", cwd: "/nope/nowhere"})).to eq([:prompt, "a prompt is required"])
      expect(described_class.problem({prompt: "go", cwd: "/nope/nowhere"}))
        .to eq([:cwd, "no such directory: /nope/nowhere"])
    end
  end

  describe "attach" do
    it "turns each [Image #n] into a mention of the nth path, in any case" do
      expect(described_class.attach("make it [Image #2], not [image #1]", ["/i/a.png", "/i/b c.jpg"]))
        .to eq("make it @/i/b\\ c.jpg, not @/i/a.png")
    end

    it "puts every path the prompt never points at on the end, one per line" do
      expect(described_class.attach("fix [Image #2]", %w[/i/a.png /i/b.png /i/c.png]))
        .to eq("fix @/i/b.png\n\n@/i/a.png\n@/i/c.png")
    end

    it "leaves a token past the last image as text" do
      expect(described_class.attach("see [Image #3] and [Image #0]", ["/i/a.png"]))
        .to eq("see [Image #3] and [Image #0]\n\n@/i/a.png")
    end

    it "leaves a prompt without images as it was" do
      expect(described_class.attach("just [Image #1]", [])).to eq("just [Image #1]")
    end
  end

  describe "strip_worktree" do
    it "moves a directory inside an agent's worktree back to the repo it was cut from" do
      strip = described_class.method(:strip_worktree)
      expect(strip.call("/code/inbox/.claude/worktrees/foo")).to eq("/code/inbox")
      expect(strip.call("/code/inbox/.claude/worktrees/foo/lib")).to eq("/code/inbox")
      expect(strip.call("/code/inbox/lib")).to eq("/code/inbox/lib")
    end
  end
end
