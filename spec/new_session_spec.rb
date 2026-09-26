# frozen_string_literal: true

require "claude_inbox/new_session_form"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::AgentsClient do
  it "builds claude --bg arguments, leaving unset ones off" do
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "fix it", model: nil, effort: nil, permission_mode: nil, worktree: false, name: nil)
    expect(a).to eq(["claude", "--bg", "--", "fix it"])
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "fix it", model: "opus", effort: "high", permission_mode: "acceptEdits", worktree: true, name: "flaky")
    expect(a).to eq(["claude", "--bg", "--model", "opus", "--effort", "high", "--permission-mode", "acceptEdits", "--name", "flaky", "--worktree", "--", "fix it"])
  end

  it "puts --remote-control last, where its optional name cannot eat the prompt" do
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "fix it", name: "flaky", remote: true)
    expect(a).to eq(["claude", "--bg", "--name", "flaky", "--remote-control", "--", "fix it"])
  end

  it "keeps a prompt that starts with a dash a prompt" do
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "-x is not a flag", remote: true)
    expect(a).to eq(["claude", "--bg", "--remote-control", "--", "-x is not a flag"])
  end

  it "mentions a file the way the CLI's own prompt does, spaces escaped" do
    expect(ClaudeInbox::AgentsClient.mention("/tmp/Screen Shot.png")).to eq("@/tmp/Screen\\ Shot.png")
  end
end

RSpec.describe ClaudeInbox::NewSessionForm do
  # An empty home, so the developer's own ~/.claude settings stay out of the defaults.
  let(:home) { Dir.mktmpdir }
  after { FileUtils.rm_rf(home) }

  let(:form) { ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home) }

  def type(str) = str.each_char { |c| form.press(c, c) }

  it "starts on the prompt and types into it, spaces included" do
    expect(form.focused.key).to eq(:prompt)
    "fix the".each_char { |c| form.press((c == " ") ? :space : c, c) }
    expect(form.values[:prompt]).to eq("fix the")
  end

  it "moves between fields with tab and cycles choices with h/l" do
    3.times { form.press(:tab, "\t") }
    expect(form.focused.key).to eq(:model)
    form.press("l", "l")
    expect(form.values[:model]).to eq("fable")
    form.press("h", "h")
    form.press("h", "h")
    expect(form.values[:model]).to eq("haiku")
    form.press(:back_tab, "\e[Z")
    expect(form.focused.key).to eq(:cwd)
  end

  it "refuses to submit without a prompt" do
    expect(form.press(:ctrl_s, "\x13")).to eq(:changed)
    expect(form.footer).to include("a prompt is required")
  end

  it "refuses a missing directory" do
    type("do it")
    2.times { form.press(:tab, "\t") }
    form.press(:ctrl_u, "\x15")
    type("/nope/nowhere")
    expect(form.press(:ctrl_s, "\x13")).to eq(:changed)
    expect(form.footer).to include("no such directory")
    form.press(:tab, "\t")
    expect(form.focused.key).to eq(:model)
  end

  it "submits with expanded values" do
    type("do it")
    6.times { form.press(:tab, "\t") }
    form.press(:space, " ")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    v = form.values
    expect(v[:worktree]).to be(true)
    expect(v[:remote]).to be(false)
    expect(v[:name]).to be_nil
    expect(v[:cwd]).to eq(Dir.pwd)
  end

  it "moves to the next field on enter instead of starting" do
    type("do it")
    3.times { form.press(:tab, "\t") }
    form.press("l", "l")
    expect(form.press(:return, "\r")).to eq(:changed)
    expect(form.focused.key).to eq(:effort)
    expect(form.values[:model]).to eq("fable")
  end

  it "starts and attaches on ^O, starts and stays put on ^S" do
    type("do it")
    expect(form.press(:ctrl_o, "\x0f")).to eq(:start_and_attach)
    other = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
    type_into(other, "do it")
    expect(other.press(:ctrl_s, "\x13")).to eq(:start)
  end

  def type_into(f, str) = str.each_char { |c| f.press((c == " ") ? :space : c, c) }

  it "goes busy on ^S and ignores keys until the App reports back" do
    type("do it")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    expect(form.footer).to include("starting session…")
    expect(form.press("x", "x")).to eq(:changed)
    expect(form.values[:prompt]).to eq("do it")
  end

  it "hands the prompt back with the failure once the App reports it failed" do
    type("do it")
    form.press(:ctrl_s, "\x13")
    form.submission_failed("claude --bg failed: not a trusted directory")
    expect(form.footer).to include("not a trusted directory")
    expect(form.values[:prompt]).to eq("do it")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
  end

  describe "images" do
    let(:clip) { ClaudeInbox::Images::Clipboard.new(nil, nil) }
    let(:form) { ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), clipboard: -> { clip }, home: home) }

    it "attaches the clipboard's image on an empty paste, as a token in the prompt" do
      clip.image = "/tmp/shot.png"
      type("match ")
      expect(form.paste("")).to eq(:changed)
      expect(form.values[:prompt]).to eq("match @/tmp/shot.png")
      rows = form.screen(80, 24)
      expect(rows.find { |r| r.include?("match") }).to include("[Image #1]")
    end

    it "attaches it on ^V too, for terminals without bracketed paste" do
      clip.image = "/tmp/shot.png"
      form.press(:ctrl_v, "\x16")
      expect(form.values[:prompt]).to eq("@/tmp/shot.png")
    end

    it "pastes text from the clipboard when that is what is there" do
      clip.text = "fix it"
      form.press(:ctrl_v, "\x16")
      expect(form.values[:prompt]).to eq("fix it")
      clip.text = nil
      form.press(:ctrl_v, "\x16")
      expect(form.footer).to include("nothing on the clipboard")
    end

    it "keeps an image out of the one-line fields" do
      clip.image = "/tmp/shot.png"
      form.press(:tab, "\t")
      form.paste("")
      expect(form.footer).to include("images go in the prompt")
      expect(form.values[:name]).to be_nil
    end

    it "attaches a dropped image file and keeps any other drop as text" do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a b.png", "x")
        type("see ")
        form.paste("#{dir}/a\\ b.png ")
        form.paste(" not #{dir}/nope.txt")
        expect(form.values[:prompt]).to eq("see @#{dir}/a\\ b.png not #{dir}/nope.txt")
      end
    end

    it "pastes multi-line text into the prompt, and flattens it into a one-line field" do
      form.paste("one\r\ntwo\rthree")
      expect(form.values[:prompt]).to eq("one\ntwo\nthree")
      form.press(:tab, "\t")
      form.paste("my\nname")
      expect(form.values[:name]).to eq("my name")
    end
  end

  it "takes a multi-line prompt: enter breaks the line, ^S starts" do
    type("first")
    form.press(:return, "\r")
    type("second")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    expect(form.values[:prompt]).to eq("first\nsecond")
    rows = form.screen(80, 24)
    box = rows.index { |r| r.include?("first") }
    expect(rows[box + 1]).to include("second")
    expect(rows.find { |r| r.include?("Name") }).not_to be_nil
  end

  it "shows the last rows of a long prompt, counting the rest in the border" do
    10.times { |i|
      type("line#{i}")
      form.press(:return, "\r")
    }
    rows = form.screen(80, 21)
    top = rows.index { |r| r.include?("┌") }
    expect(rows[top]).to include("↑ 4 more")
    expect(rows[top + 1]).to include("line4")
    expect(rows[top + 6]).to include("line9")
    expect(rows[top + 8]).to include("└")
  end

  it "shows what the defaults resolve to" do
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", {model: "opus", effortLevel: "high"}.to_json)
      f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
      rows = f.screen(100, 24)
      expect(rows.find { |r| r.include?("Model") }).to include("opus (settings)")
      expect(rows.find { |r| r.include?("Effort") }).to include("high (settings)")
      expect(rows.find { |r| r.include?("Permissions") }).to include("auto (cli default)")
      expect(f.values[:model]).to be_nil
    end
  end

  it "reads project settings from the target directory" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |proj|
        FileUtils.mkdir_p("#{home}/.claude")
        FileUtils.mkdir_p("#{proj}/.claude")
        File.write("#{home}/.claude/settings.json", {model: "opus"}.to_json)
        File.write("#{proj}/.claude/settings.local.json", {permissions: {defaultMode: "plan"}}.to_json)
        f = ClaudeInbox::NewSessionForm.new(cwd: proj, pastel: Pastel.new(enabled: false), home: home)
        rows = f.screen(100, 24)
        expect(rows.find { |r| r.include?("Model") }).to include("opus (settings)")
        expect(rows.find { |r| r.include?("Permissions") }).to include("plan (settings)")
      end
    end
  end

  it "starts with Remote Control when settings turn it on for all sessions" do
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
      f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
      expect(f.screen(100, 24).find { |r| r.include?("Remote Control") }).to include("yes (settings)")
      expect(f.values[:remote]).to be(true)
      7.times { f.press(:tab, "\t") }
      f.press("l", "l")
      expect(f.values[:remote]).to be(false)
    end
  end

  it "leaves Remote Control off when nothing turns it on" do
    Dir.mktmpdir do |home|
      f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
      expect(f.values[:remote]).to be(false)
      7.times { f.press(:tab, "\t") }
      f.press("h", "h")
      expect(f.values[:remote]).to be(true)
    end
  end

  it "tab-completes the directory" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/apple")
      FileUtils.mkdir_p("#{root}/apricot")
      FileUtils.mkdir_p("#{root}/banana")
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
      type("#{root}/b")
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/banana/")
      form.press(:ctrl_u, "\x15")
      type("#{root}/a")
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/ap")
      expect(form.footer).to include("apple  apricot")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:cwd)
      expect(form.footer).to include("apple  apricot")
      type("pl")
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/apple/")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:model)
    end
  end

  it "edits the prompt under the cursor, and still cycles choices with arrows" do
    type("abd")
    form.press(:left, "\e[D")
    type("c")
    expect(form.values[:prompt]).to eq("abcd")
    form.press(:backspace, "\x7f")
    form.press(:home, "\e[H")
    type("A")
    expect(form.values[:prompt]).to eq("Aabd")
    3.times { form.press(:tab, "\t") }
    form.press(:right, "\e[C")
    expect(form.values[:model]).to eq("fable")
  end

  it "draws the cursor on the cell it sits on" do
    f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: true), home: home)
    "ab".each_char { |c| f.press(c, c) }
    f.press(:left, "\e[D")
    expect(f.screen(80, 24).join("\n")).to include("a\e[7mb\e[0m")
  end

  it "cancels on escape when the prompt is empty" do
    expect(form.press(:escape, "\e")).to eq(:cancel)
  end

  it "asks to confirm on escape once the prompt has text, then honors the answer" do
    form.press("h", "h")
    expect(form.press(:escape, "\e")).to eq(:changed)
    expect(form.screen(80, 24).join("\n")).to include("Discard this session?")
    expect(form.footer).to include("discard")
    expect(form.press("n", "n")).to eq(:changed)
    expect(form.screen(80, 24).join("\n")).to include("New session")
    expect(form.press(:escape, "\e")).to eq(:changed)
    expect(form.press("y", "y")).to eq(:cancel)
  end

  describe "slash commands" do
    def with_commands
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |proj|
          %w[unslop unsplit babysit].each do |n|
            FileUtils.mkdir_p("#{home}/.claude/skills/#{n}")
            File.write("#{home}/.claude/skills/#{n}/SKILL.md", "---\ndescription: #{n} does things\n---\n")
          end
          FileUtils.mkdir_p("#{proj}/.claude/commands")
          File.write("#{proj}/.claude/commands/deploy.md", "---\ndescription: Ship it\n---\n")
          f = ClaudeInbox::NewSessionForm.new(cwd: proj, pastel: Pastel.new(enabled: false), home: home)
          yield f
        end
      end
    end

    def type(f, str) = str.each_char { |c| f.press((c == " ") ? :space : c, c) }

    it "opens a menu on a leading slash and narrows it as you type" do
      with_commands do |f|
        type(f, "/")
        expect(f.menu.map(&:name)).to eq(%w[babysit deploy unslop unsplit])
        expect(f.footer).to include("pick")
        type(f, "uns")
        expect(f.menu.map(&:name)).to eq(%w[unslop unsplit])
        rows = f.screen(80, 24)
        expect(rows.find { |r| r.include?("/unsplit") }).to include("unsplit does things")
        expect(rows.find { |r| r.include?("/unslop") }).not_to be_nil
        expect(rows.find { |r| r.include?("Worktree") }).not_to be_nil
        type(f, "zz")
        expect(f.menu).to be_nil
      end
    end

    it "picks with tab or enter, leaving the cursor after the command and a space" do
      with_commands do |f|
        type(f, "/unsl")
        expect(f.press(:tab, "\t")).to eq(:changed)
        expect(f.values[:prompt]).to eq("/unslop")
        expect(f.focused.value.to_s).to eq("/unslop ")
        expect(f.menu).to be_nil
        type(f, "the readme")
        expect(f.press(:return, "\r")).to eq(:changed)
        type(f, "/dep")
        expect(f.menu.map(&:name)).to eq(%w[deploy])
        f.press(:return, "\r")
        expect(f.values[:prompt]).to eq("/unslop the readme\n/deploy")
      end
    end

    it "moves the pick with the arrows and keeps enter for picking" do
      with_commands do |f|
        type(f, "/")
        f.press(:down, "\e[B")
        expect(f.picked.name).to eq("deploy")
        f.press(:up, "\e[A")
        f.press(:up, "\e[A")
        expect(f.picked.name).to eq("unsplit")
        f.press(:return, "\r")
        expect(f.values[:prompt]).to eq("/unsplit")
        expect(f.focused.key).to eq(:prompt)
      end
    end

    it "closes the menu on escape without leaving the form, until the query changes" do
      with_commands do |f|
        type(f, "/un")
        expect(f.press(:escape, "\e")).to eq(:changed)
        expect(f.menu).to be_nil
        expect(f.press(:tab, "\t")).to eq(:changed)
        expect(f.focused.key).to eq(:name)
        f.press(:back_tab, "\e[Z")
        expect(f.menu).to be_nil
        type(f, "s")
        expect(f.menu.map(&:name)).to eq(%w[unslop unsplit])
        expect(f.press(:escape, "\e")).to eq(:changed)
        expect(f.press(:escape, "\e")).to eq(:changed)
        expect(f.footer).to include("discard")
      end
    end

    it "offers commands for a slash word anywhere in the prompt, but not mid-word" do
      with_commands do |f|
        type(f, "first do")
        f.press(:return, "\r")
        type(f, "then /uns")
        expect(f.menu.map(&:name)).to eq(%w[unslop unsplit])
        f.press(:tab, "\t")
        expect(f.values[:prompt]).to eq("first do\nthen /unslop")
        type(f, "a/b")
        expect(f.menu).to be_nil
        f.press(:ctrl_u, "\x15")
        type(f, "/unslop x")
        expect(f.menu).to be_nil
        f.press(:left, "\e[D")
        f.press(:left, "\e[D")
        expect(f.menu.map(&:name)).to eq(%w[unslop])
        f.press(:tab, "\t")
        expect(f.focused.value.to_s).to eq("/unslop  x")
      end
    end

    it "keeps the pick in view and counts the rest on the last row" do
      Dir.mktmpdir do |home|
        ("a".."j").each do |n|
          FileUtils.mkdir_p("#{home}/.claude/skills/cmd-#{n}")
          File.write("#{home}/.claude/skills/cmd-#{n}/SKILL.md", "---\ndescription: #{n}\n---\n")
        end
        f = ClaudeInbox::NewSessionForm.new(cwd: home, pastel: Pastel.new(enabled: false), home: home)
        type(f, "/")
        rows = f.screen(80, 24)
        expect(rows.count { |r| r.include?("/cmd-") }).to eq(6)
        expect(rows.find { |r| r.include?("/cmd-f") }).to include("+4 more")
        7.times { f.press(:down, "\e[B") }
        rows = f.screen(80, 24)
        expect(rows.find { |r| r.include?("/cmd-b") }).to be_nil
        expect(rows.find { |r| r.include?("/cmd-c") }).not_to be_nil
        expect(rows.find { |r| r.include?("/cmd-h") }).to include("+2 more")
      end
    end
  end
end
