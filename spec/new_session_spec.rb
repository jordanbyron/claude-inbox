# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::NewSessionForm do
  # An empty home, so the developer's own ~/.claude settings stay out of the defaults.
  let(:home) { Dir.mktmpdir }
  after { FileUtils.rm_rf(home) }

  let(:form) { described_class.new(cwd: Dir.pwd, home: home) }

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
    type(form, "do it")
    2.times { form.press(:tab, "\t") }
    form.press(:ctrl_u, "\x15")
    type(form, "/nope/nowhere")
    expect(form.press(:ctrl_s, "\x13")).to eq(:changed)
    expect(form.footer).to include("no such directory")
    form.press(:tab, "\t")
    expect(form.focused.key).to eq(:model)
  end

  it "submits with expanded values" do
    type(form, "do it")
    6.times { form.press(:tab, "\t") }
    form.press(:space, " ")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    v = form.values
    expect(v[:worktree]).to be(true)
    expect(v[:remote]).to be(false)
    expect(v[:name]).to be_nil
    expect(v[:cwd]).to eq(Dir.pwd)
  end

  it "picks a color from the ones /color offers, none by default" do
    expect(form.values[:color]).to be_nil
    form.press(:back_tab, "\e[Z")
    expect(form.focused.key).to eq(:color)
    form.press("l", "l")
    expect(form.values[:color]).to eq("red")
    expect(form.screen(100, 24).find { |r| r.include?("Color") }).to include("none")
  end

  it "moves to the next field on enter instead of starting" do
    type(form, "do it")
    3.times { form.press(:tab, "\t") }
    form.press("l", "l")
    expect(form.press(:return, "\r")).to eq(:changed)
    expect(form.focused.key).to eq(:effort)
    expect(form.values[:model]).to eq("fable")
  end

  it "starts and attaches on ^O, starts and stays put on ^S" do
    type(form, "do it")
    expect(form.press(:ctrl_o, "\x0f")).to eq(:start_and_attach)
    other = described_class.new(cwd: Dir.pwd, home: home)
    type(other, "do it")
    expect(other.press(:ctrl_s, "\x13")).to eq(:start)
  end

  it "goes busy on ^S and ignores keys until the App reports back" do
    type(form, "do it")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    expect(form.footer).to include("starting session…")
    expect(form.press("x", "x")).to eq(:changed)
    expect(form.values[:prompt]).to eq("do it")
  end

  it "hands the prompt back with the failure once the App reports it failed" do
    type(form, "do it")
    form.press(:ctrl_s, "\x13")
    form.submission_failed("claude --bg failed: not a trusted directory")
    expect(form.footer).to include("not a trusted directory")
    expect(form.values[:prompt]).to eq("do it")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
  end

  describe "images" do
    let(:clip) { ClaudeInbox::Images::Clipboard.new(nil, nil) }
    let(:form) do
      described_class.new(cwd: Dir.pwd, clipboard: -> { clip }, home: home)
    end

    it "attaches the clipboard's image on an empty paste, as a token in the prompt" do
      clip.image = "/tmp/shot.png"
      type(form, "match ")
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
        type(form, "see ")
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

    it "folds a long paste in the prompt into a token and starts with all of it" do
      log = (1..40).map { |i| "error #{i}" }.join("\n")
      type(form, "why ")
      form.paste(log)
      rows = form.screen(80, 30)
      expect(rows.find { |r| r.include?("why ") }).to include("[Pasted text #1 +39 lines]")
      expect(rows.join).not_to include("error 40")
      expect(form.values[:prompt]).to eq("why #{log}")
    end
  end

  it "takes a multi-line prompt: enter breaks the line, ^S starts" do
    type(form, "first")
    form.press(:return, "\r")
    type(form, "second")
    expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    expect(form.values[:prompt]).to eq("first\nsecond")
    rows = form.screen(80, 24)
    box = rows.index { |r| r.include?("first") }
    expect(rows[box + 1]).to include("second")
    expect(rows.find { |r| r.include?("Name") }).not_to be_nil
  end

  it "shows the last rows of a long prompt, counting the rest in the border" do
    10.times { |i|
      type(form, "line#{i}")
      form.press(:return, "\r")
    }
    rows = form.screen(80, 22)
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
      f = described_class.new(cwd: Dir.pwd, home: home)
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
        f = described_class.new(cwd: proj, home: home)
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
      f = described_class.new(cwd: Dir.pwd, home: home)
      expect(f.screen(100, 24).find { |r| r.include?("Remote Control") }).to include("yes (settings)")
      expect(f.values[:remote]).to be(true)
      7.times { f.press(:tab, "\t") }
      f.press("l", "l")
      expect(f.values[:remote]).to be(false)
    end
  end

  it "leaves Remote Control off when nothing turns it on" do
    Dir.mktmpdir do |home|
      f = described_class.new(cwd: Dir.pwd, home: home)
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
      type(form, "#{root}/b")
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/banana/")
      form.press(:ctrl_u, "\x15")
      type(form, "#{root}/a")
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/ap")
      expect(ClaudeInbox::Text.strip_ansi(form.footer)).to include("apple  apricot")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:cwd)
      expect(ClaudeInbox::Text.strip_ansi(form.footer)).to include("apple  apricot")
      type(form, "pl")
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{root}/apple/")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:model)
    end
  end

  it "edits the prompt under the cursor, and still cycles choices with arrows" do
    type(form, "abd")
    form.press(:left, "\e[D")
    type(form, "c")
    expect(form.values[:prompt]).to eq("abcd")
    form.press(:backspace, "\x7f")
    form.press(:home, "\e[H")
    type(form, "A")
    expect(form.values[:prompt]).to eq("Aabd")
    3.times { form.press(:tab, "\t") }
    form.press(:right, "\e[C")
    expect(form.values[:model]).to eq("fable")
  end

  it "draws the cursor on the cell it sits on" do
    f = described_class.new(cwd: Dir.pwd, home: home)
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

  it "warns on option-s and option-o, slips for the ctrl keys, and leaves the prompt alone" do
    form.press("h", "h")
    expect(form.press(:alt_s, "\es")).to eq(:changed)
    expect(form.footer).to include("ctrl-s starts it")
    expect(form.press(:alt_o, "\eo")).to eq(:changed)
    expect(form.footer).to include("ctrl-o starts and attaches")
    expect(form.screen(80, 24).join("\n")).not_to include("Discard this session?")
    expect(form.values[:prompt]).to eq("h")
  end

  describe "recent directories" do
    let(:dirs) { %w[code/inbox code/site work/site].map { |d| File.join(home, d).tap { |p| FileUtils.mkdir_p(p) } } }
    let(:form) { described_class.new(cwd: Dir.pwd, home: home, dirs: dirs) }

    it "stays shut until the field is edited, so tabbing through keeps the directory" do
      2.times { form.press(:tab, "\t") }
      expect(form.menu).to be_nil
      expect(ClaudeInbox::Text.strip_ansi(form.footer)).to include("^U recent")
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:model)
      expect(form.values[:cwd]).to eq(Dir.pwd)
    end

    it "lists them all on a cleared field, under the Directory row, by their shortest labels" do
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
      expect(form.menu.map(&:label)).to eq(%w[inbox code/site work/site])
      rows = form.screen(100, 30)
      at = rows.index { |r| r.include?("Directory") }
      expect(rows[at + 1]).to include("inbox", "~/code/inbox")
      expect(rows.index { |r| r.include?("Model") }).to eq(at + 4)
    end

    it "narrows as you type and picks with arrows and enter, then closes" do
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
      type(form, "site")
      expect(form.menu.map(&:label)).to eq(%w[code/site work/site])
      form.press(:down, "\e[B")
      expect(form.press(:return, "\r")).to eq(:changed)
      expect(form.values[:cwd]).to eq(dirs[2])
      expect(form.menu).to be_nil
      expect(form.focused.key).to eq(:cwd)
      form.press(:return, "\r")
      expect(form.focused.key).to eq(:model)
    end

    it "gives tab back to path completion once escaped or when nothing matches" do
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
      type(form, "#{home}/wo")
      expect(form.menu.map(&:label)).to eq(%w[work/site])
      form.press(:escape, "\e")
      expect(form.menu).to be_nil
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("#{home}/work/")
      type(form, "zz")
      expect(form.menu).to be_nil
    end
  end

  describe "slash commands" do
    # Three skills in home and one command in the project.
    let(:proj) { Dir.mktmpdir }
    after { FileUtils.rm_rf(proj) }

    let(:form) { described_class.new(cwd: proj, home: home) }

    before do
      %w[unslop unsplit babysit].each do |n|
        FileUtils.mkdir_p("#{home}/.claude/skills/#{n}")
        File.write("#{home}/.claude/skills/#{n}/SKILL.md", "---\ndescription: #{n} does things\n---\n")
      end
      FileUtils.mkdir_p("#{proj}/.claude/commands")
      File.write("#{proj}/.claude/commands/deploy.md", "---\ndescription: Ship it\n---\n")
    end

    it "opens a menu on a leading slash and narrows it as you type" do
      type(form, "/")
      expect(form.menu.map(&:name)).to eq(%w[babysit deploy unslop unsplit])
      expect(form.footer).to include("pick")
      type(form, "uns")
      expect(form.menu.map(&:name)).to eq(%w[unslop unsplit])
      rows = form.screen(80, 24)
      expect(rows.find { |r| r.include?("/unsplit") }).to include("unsplit does things")
      expect(rows.find { |r| r.include?("/unslop") }).not_to be_nil
      expect(rows.find { |r| r.include?("Worktree") }).not_to be_nil
      type(form, "zz")
      expect(form.menu).to be_nil
    end

    it "picks with tab or enter, leaving the cursor after the command and a space" do
      type(form, "/unsl")
      expect(form.press(:tab, "\t")).to eq(:changed)
      expect(form.values[:prompt]).to eq("/unslop")
      expect(form.focused.value.to_s).to eq("/unslop ")
      expect(form.menu).to be_nil
      type(form, "the readme")
      expect(form.press(:return, "\r")).to eq(:changed)
      type(form, "/dep")
      expect(form.menu.map(&:name)).to eq(%w[deploy])
      form.press(:return, "\r")
      expect(form.values[:prompt]).to eq("/unslop the readme\n/deploy")
    end

    it "moves the pick with the arrows and keeps enter for picking" do
      type(form, "/")
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
      type(form, "/un")
      expect(form.press(:escape, "\e")).to eq(:changed)
      expect(form.menu).to be_nil
      expect(form.press(:tab, "\t")).to eq(:changed)
      expect(form.focused.key).to eq(:name)
      form.press(:back_tab, "\e[Z")
      expect(form.menu).to be_nil
      type(form, "s")
      expect(form.menu.map(&:name)).to eq(%w[unslop unsplit])
      expect(form.press(:escape, "\e")).to eq(:changed)
      expect(form.press(:escape, "\e")).to eq(:changed)
      expect(form.footer).to include("discard")
    end

    it "offers commands for a slash word anywhere in the prompt, but not mid-word" do
      type(form, "first do")
      form.press(:return, "\r")
      type(form, "then /uns")
      expect(form.menu.map(&:name)).to eq(%w[unslop unsplit])
      form.press(:tab, "\t")
      expect(form.values[:prompt]).to eq("first do\nthen /unslop")
      type(form, "a/b")
      expect(form.menu).to be_nil
      form.press(:ctrl_u, "\x15")
      type(form, "/unslop x")
      expect(form.menu).to be_nil
      form.press(:left, "\e[D")
      form.press(:left, "\e[D")
      expect(form.menu.map(&:name)).to eq(%w[unslop])
      form.press(:tab, "\t")
      expect(form.focused.value.to_s).to eq("/unslop  x")
    end

    it "keeps the pick in view and counts the rest on the last row" do
      Dir.mktmpdir do |home|
        ("a".."j").each do |n|
          FileUtils.mkdir_p("#{home}/.claude/skills/cmd-#{n}")
          File.write("#{home}/.claude/skills/cmd-#{n}/SKILL.md", "---\ndescription: #{n}\n---\n")
        end
        f = described_class.new(cwd: home, home: home)
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

  describe "with Codex to start in too" do
    let(:clip) { ClaudeInbox::Images::Clipboard.new("/tmp/shot.png", nil) }
    let(:form) do
      described_class.new(cwd: Dir.pwd, home: home, clipboard: -> { clip },
        choices: {claude: ClaudeInbox::Claude::AgentsClient::CHOICES,
                  codex: {model: %w[default gpt-6.1-sol], effort: %w[default low high], permission_mode: ClaudeInbox::Codex::ThreadsClient::PERMISSION_MODES}})
    end
    let(:rows) { -> { form.screen(100, 30).map { |r| ClaudeInbox::Text.strip_ansi(r) } } }
    let(:labels) { -> { rows.call.filter_map { |r| r[/\A  (?:▶ |  )(\S.{13})/, 1]&.strip } } }

    it "asks which harness under the prompt, and keeps only Codex's fields for Codex" do
      form.press(:tab, "\t")
      expect(form.focused.key).to eq(:harness)
      expect(labels.call).to eq(["Prompt", "Harness", "Name", "Directory", "Model", "Effort", "Permissions", "Worktree", "Remote Control", "Color"])
      form.press("l", "l")
      expect(labels.call).to eq(%w[Prompt Harness Directory Model Effort Permissions])
      expect(rows.call.find { |r| r.include?("Model") }).to include("codex config", "gpt-6.1-sol")
      expect(rows.call.find { |r| r.include?("Permissions") }).to include("workspace-write", "full-access")
    end

    it "submits Codex's values, an image as a file beside the text" do
      type(form, "look at ")
      form.paste("")
      form.press(:tab, "\t")
      form.press("l", "l")
      3.times { form.press(:tab, "\t") }
      expect(form.focused.key).to eq(:effort)
      form.press("l", "l")
      form.press(:tab, "\t")
      form.press("l", "l")
      expect(form.values).to eq(harness: :codex, prompt: "look at [Image #1]", cwd: Dir.pwd, model: nil, effort: "low",
        permission_mode: "read-only", images: ["/tmp/shot.png"])
      expect(form.press(:ctrl_s, "\x13")).to eq(:start)
    end

    it "starts the model and permissions over when the harness changes" do
      form.press(:tab, "\t")
      form.press("l", "l")
      2.times { form.press(:tab, "\t") }
      form.press("l", "l")
      expect(form.values[:model]).to eq("gpt-6.1-sol")
      2.times { form.press(:back_tab, "\e[Z") }
      form.press("l", "l")
      expect(form.values).to include(harness: :claude, model: nil)
    end
  end

  it "asks no harness when only Claude can start one" do
    form.press(:tab, "\t")
    expect(form.focused.key).to eq(:name)
    expect(form.values[:harness]).to eq(:claude)
  end
end
