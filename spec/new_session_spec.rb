# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::NewSessionForm do
  # An empty home, so the developer's own ~/.claude settings stay out of the defaults.
  let(:home) { Dir.mktmpdir }
  after { FileUtils.rm_rf(home) }

  let(:cwd) { Dir.pwd }
  let(:form) { described_class.new(cwd: cwd, pastel: Pastel.new(enabled: false), home: home) }

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

  context "with a prompt typed" do
    before { "do it".each_char { |c| form.press(c, c) } }

    it "refuses a missing directory" do
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
      "/nope/nowhere".each_char { |c| form.press(c, c) }
      expect(form.press(:ctrl_s, "\x13")).to eq(:changed)
      expect(form.footer).to include("no such directory")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:model)
    end

    it "submits with expanded values" do
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
      3.times { form.press(:tab, "\t") }
      form.press("l", "l")
      expect(form.press(:return, "\r")).to eq(:changed)
      expect(form.focused.key).to eq(:effort)
      expect(form.values[:model]).to eq("fable")
    end

    it "starts and attaches on ^O" do
      expect(form.press(:ctrl_o, "\x0f")).to eq(:start_and_attach)
    end

    it "starts and stays put on ^S" do
      expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    end

    it "goes busy on ^S and ignores keys until the App reports back" do
      expect(form.press(:ctrl_s, "\x13")).to eq(:start)
      expect(form.footer).to include("starting session…")
      expect(form.press("x", "x")).to eq(:changed)
      expect(form.values[:prompt]).to eq("do it")
    end

    it "hands the prompt back with the failure once the App reports it failed" do
      form.press(:ctrl_s, "\x13")
      form.submission_failed("claude --bg failed: not a trusted directory")
      expect(form.footer).to include("not a trusted directory")
      expect(form.values[:prompt]).to eq("do it")
      expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    end
  end

  describe "images" do
    let(:clip) { ClaudeInbox::Images::Clipboard.new(nil, nil) }
    let(:form) { described_class.new(cwd: cwd, pastel: Pastel.new(enabled: false), clipboard: -> { clip }, home: home) }

    it "attaches the clipboard's image on an empty paste, as a token in the prompt" do
      clip.image = "/tmp/shot.png"
      "match ".each_char { |c| form.press(c, c) }
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
      File.write("#{home}/a b.png", "x")
      "see ".each_char { |c| form.press(c, c) }
      form.paste("#{home}/a\\ b.png ")
      form.paste(" not #{home}/nope.txt")
      expect(form.values[:prompt]).to eq("see @#{home}/a\\ b.png not #{home}/nope.txt")
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
    "first".each_char { |c| form.press(c, c) }
    form.press(:return, "\r")
    "second".each_char { |c| form.press(c, c) }
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    expect(form.values[:prompt]).to eq("first\nsecond")
    rows = form.screen(80, 24)
    box = rows.index { |r| r.include?("first") }
    expect(rows[box + 1]).to include("second")
    expect(rows.find { |r| r.include?("Name") }).not_to be_nil
  end

  it "shows the last rows of a long prompt, counting the rest in the border" do
    10.times do |i|
      "line#{i}".each_char { |c| form.press(c, c) }
      form.press(:return, "\r")
    end
    rows = form.screen(80, 21)
    top = rows.index { |r| r.include?("┌") }
    expect(rows[top]).to include("↑ 4 more")
    expect(rows[top + 1]).to include("line4")
    expect(rows[top + 6]).to include("line9")
    expect(rows[top + 8]).to include("└")
  end

  context "with a model and effort in user settings" do
    before do
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", {model: "opus", effortLevel: "high"}.to_json)
    end

    it "shows what the defaults resolve to" do
      rows = form.screen(100, 24)
      expect(rows.find { |r| r.include?("Model") }).to include("opus (settings)")
      expect(rows.find { |r| r.include?("Effort") }).to include("high (settings)")
      expect(rows.find { |r| r.include?("Permissions") }).to include("auto (cli default)")
      expect(form.values[:model]).to be_nil
    end
  end

  context "aimed at a project with settings of its own" do
    let(:cwd) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p("#{home}/.claude")
      FileUtils.mkdir_p("#{cwd}/.claude")
      File.write("#{home}/.claude/settings.json", {model: "opus"}.to_json)
      File.write("#{cwd}/.claude/settings.local.json", {permissions: {defaultMode: "plan"}}.to_json)
    end

    after { FileUtils.rm_rf(cwd) }

    it "reads project settings from the target directory" do
      rows = form.screen(100, 24)
      expect(rows.find { |r| r.include?("Model") }).to include("opus (settings)")
      expect(rows.find { |r| r.include?("Permissions") }).to include("plan (settings)")
    end
  end

  context "when settings turn Remote Control on for all sessions" do
    before do
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
    end

    it "starts with Remote Control, and lets it be switched off" do
      expect(form.screen(100, 24).find { |r| r.include?("Remote Control") }).to include("yes (settings)")
      expect(form.values[:remote]).to be(true)
      7.times { form.press(:tab, "\t") }
      form.press("l", "l")
      expect(form.values[:remote]).to be(false)
    end
  end

  it "leaves Remote Control off when nothing turns it on" do
    expect(form.values[:remote]).to be(false)
    7.times { form.press(:tab, "\t") }
    form.press("h", "h")
    expect(form.values[:remote]).to be(true)
  end

  context "with directories to complete" do
    let(:root) { Dir.mktmpdir }

    before do
      %w[apple apricot banana].each { |d| FileUtils.mkdir_p("#{root}/#{d}") }
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
    end

    after { FileUtils.rm_rf(root) }

    it "tab-completes the directory" do
      "#{root}/b".each_char { |c| form.press(c, c) }
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/banana/")
      form.press(:ctrl_u, "\x15")
      "#{root}/a".each_char { |c| form.press(c, c) }
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/ap")
      expect(form.footer).to include("apple  apricot")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:cwd)
      expect(form.footer).to include("apple  apricot")
      "pl".each_char { |c| form.press(c, c) }
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/apple/")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:model)
    end
  end

  it "edits the prompt under the cursor, and still cycles choices with arrows" do
    "abd".each_char { |c| form.press(c, c) }
    form.press(:left, "\e[D")
    form.press("c", "c")
    expect(form.values[:prompt]).to eq("abcd")
    form.press(:backspace, "\x7f")
    form.press(:home, "\e[H")
    form.press("A", "A")
    expect(form.values[:prompt]).to eq("Aabd")
    3.times { form.press(:tab, "\t") }
    form.press(:right, "\e[C")
    expect(form.values[:model]).to eq("fable")
  end

  context "in color" do
    let(:form) { described_class.new(cwd: cwd, pastel: Pastel.new(enabled: true), home: home) }

    it "draws the cursor on the cell it sits on" do
      "ab".each_char { |c| form.press(c, c) }
      form.press(:left, "\e[D")
      expect(form.screen(80, 24).join("\n")).to include("a\e[7mb\e[0m")
    end
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
    context "with three user skills and a project command" do
      let(:cwd) { Dir.mktmpdir }

      before do
        %w[unslop unsplit babysit].each do |n|
          FileUtils.mkdir_p("#{home}/.claude/skills/#{n}")
          File.write("#{home}/.claude/skills/#{n}/SKILL.md", "---\ndescription: #{n} does things\n---\n")
        end
        FileUtils.mkdir_p("#{cwd}/.claude/commands")
        File.write("#{cwd}/.claude/commands/deploy.md", "---\ndescription: Ship it\n---\n")
      end

      after { FileUtils.rm_rf(cwd) }

      it "opens a menu on a leading slash and narrows it as you type" do
        form.press("/", "/")
        expect(form.menu.map(&:name)).to eq(%w[babysit deploy unslop unsplit])
        expect(form.footer).to include("pick")
        "uns".each_char { |c| form.press(c, c) }
        expect(form.menu.map(&:name)).to eq(%w[unslop unsplit])
        rows = form.screen(80, 24)
        expect(rows.find { |r| r.include?("/unsplit") }).to include("unsplit does things")
        expect(rows.find { |r| r.include?("/unslop") }).not_to be_nil
        expect(rows.find { |r| r.include?("Worktree") }).not_to be_nil
        "zz".each_char { |c| form.press(c, c) }
        expect(form.menu).to be_nil
      end

      it "picks with tab or enter, leaving the cursor after the command and a space" do
        "/unsl".each_char { |c| form.press(c, c) }
        expect(form.press(:tab, "\t")).to eq(:changed)
        expect(form.values[:prompt]).to eq("/unslop")
        expect(form.focused.value.to_s).to eq("/unslop ")
        expect(form.menu).to be_nil
        "the readme".each_char { |c| form.press(c, c) }
        expect(form.press(:return, "\r")).to eq(:changed)
        "/dep".each_char { |c| form.press(c, c) }
        expect(form.menu.map(&:name)).to eq(%w[deploy])
        form.press(:return, "\r")
        expect(form.values[:prompt]).to eq("/unslop the readme\n/deploy")
      end

      it "moves the pick with the arrows and keeps enter for picking" do
        form.press("/", "/")
        form.press(:down, "\e[B")
        expect(form.picked.name).to eq("deploy")
        form.press(:up, "\e[A")
        form.press(:up, "\e[A")
        expect(form.picked.name).to eq("unsplit")
        form.press(:return, "\r")
        expect(form.values[:prompt]).to eq("/unsplit")
        expect(form.focused.key).to eq(:prompt)
      end

      it "closes the menu on escape without leaving the form, until the query changes" do
        "/un".each_char { |c| form.press(c, c) }
        expect(form.press(:escape, "\e")).to eq(:changed)
        expect(form.menu).to be_nil
        expect(form.press(:tab, "\t")).to eq(:changed)
        expect(form.focused.key).to eq(:name)
        form.press(:back_tab, "\e[Z")
        expect(form.menu).to be_nil
        form.press("s", "s")
        expect(form.menu.map(&:name)).to eq(%w[unslop unsplit])
        expect(form.press(:escape, "\e")).to eq(:changed)
        expect(form.press(:escape, "\e")).to eq(:changed)
        expect(form.footer).to include("discard")
      end

      it "offers commands for a slash word anywhere in the prompt, but not mid-word" do
        "first do".each_char { |c| form.press(c, c) }
        form.press(:return, "\r")
        "then /uns".each_char { |c| form.press(c, c) }
        expect(form.menu.map(&:name)).to eq(%w[unslop unsplit])
        form.press(:tab, "\t")
        expect(form.values[:prompt]).to eq("first do\nthen /unslop")
        "a/b".each_char { |c| form.press(c, c) }
        expect(form.menu).to be_nil
        form.press(:ctrl_u, "\x15")
        "/unslop x".each_char { |c| form.press(c, c) }
        expect(form.menu).to be_nil
        form.press(:left, "\e[D")
        form.press(:left, "\e[D")
        expect(form.menu.map(&:name)).to eq(%w[unslop])
        form.press(:tab, "\t")
        expect(form.focused.value.to_s).to eq("/unslop  x")
      end
    end

    context "with more commands than the menu shows" do
      let(:cwd) { home }

      before do
        ("a".."j").each do |n|
          FileUtils.mkdir_p("#{home}/.claude/skills/cmd-#{n}")
          File.write("#{home}/.claude/skills/cmd-#{n}/SKILL.md", "---\ndescription: #{n}\n---\n")
        end
        form.press("/", "/")
      end

      it "keeps the pick in view and counts the rest on the last row" do
        rows = form.screen(80, 24)
        expect(rows.count { |r| r.include?("/cmd-") }).to eq(6)
        expect(rows.find { |r| r.include?("/cmd-f") }).to include("+4 more")
        7.times { form.press(:down, "\e[B") }
        rows = form.screen(80, 24)
        expect(rows.find { |r| r.include?("/cmd-b") }).to be_nil
        expect(rows.find { |r| r.include?("/cmd-c") }).not_to be_nil
        expect(rows.find { |r| r.include?("/cmd-h") }).to include("+2 more")
      end
    end
  end
end
