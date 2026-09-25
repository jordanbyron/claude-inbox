# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/new_session_form"
require "tmpdir"
require "fileutils"
require "json"

describe ClaudeInbox::AgentsClient do
  it "builds claude --bg arguments, leaving defaults off" do
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "fix it", model: "default", effort: "default", permission_mode: "default", worktree: false, name: nil)
    _(a).must_equal ["claude", "--bg", "fix it"]
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "fix it", model: "opus", effort: "high", permission_mode: "acceptEdits", worktree: true, name: "flaky")
    _(a).must_equal ["claude", "--bg", "fix it", "--model", "opus", "--effort", "high", "--permission-mode", "acceptEdits", "--name", "flaky", "--worktree"]
  end

  it "puts --remote-control last, where its optional name cannot eat the prompt" do
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "fix it", name: "flaky", remote: true)
    _(a).must_equal ["claude", "--bg", "fix it", "--name", "flaky", "--remote-control"]
  end

  it "mentions a file the way the CLI's own prompt does, spaces escaped" do
    _(ClaudeInbox::AgentsClient.mention("/tmp/Screen Shot.png")).must_equal "@/tmp/Screen\\ Shot.png"
  end
end

describe ClaudeInbox::NewSessionForm do
  let(:form) { ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false)) }

  def type(str) = str.each_char { |c| form.press(c, c) }

  it "starts on the prompt and types into it, spaces included" do
    _(form.focused.key).must_equal :prompt
    "fix the".each_char { |c| form.press((c == " ") ? :space : c, c) }
    _(form.values[:prompt]).must_equal "fix the"
  end

  it "moves between fields with tab and cycles choices with h/l" do
    3.times { form.press(:tab, "\t") }
    _(form.focused.key).must_equal :model
    form.press("l", "l")
    _(form.values[:model]).must_equal "fable"
    form.press("h", "h")
    form.press("h", "h")
    _(form.values[:model]).must_equal "haiku"
    form.press(:back_tab, "\e[Z")
    _(form.focused.key).must_equal :cwd
  end

  it "refuses to submit without a prompt" do
    _(form.press(:ctrl_s, "\x13")).must_equal :changed
    _(form.footer).must_include "a prompt is required"
  end

  it "refuses a missing directory" do
    type("do it")
    2.times { form.press(:tab, "\t") }
    form.press(:ctrl_u, "\x15")
    type("/nope/nowhere")
    _(form.press(:ctrl_s, "\x13")).must_equal :changed
    _(form.footer).must_include "no such directory"
    form.press(:tab, "\t")
    _(form.focused.key).must_equal :model
  end

  it "submits with expanded values" do
    type("do it")
    6.times { form.press(:tab, "\t") }
    form.press(:space, " ")
    _(form.press(:ctrl_s, "\x13")).must_equal :start
    v = form.values
    _(v[:worktree]).must_equal true
    _(v[:remote]).must_equal false
    _(v[:name]).must_be_nil
    _(v[:cwd]).must_equal Dir.pwd
  end

  it "moves to the next field on enter instead of starting" do
    type("do it")
    3.times { form.press(:tab, "\t") }
    form.press("l", "l")
    _(form.press(:return, "\r")).must_equal :changed
    _(form.focused.key).must_equal :effort
    _(form.values[:model]).must_equal "fable"
  end

  it "starts and attaches on ^O, starts and stays put on ^S" do
    type("do it")
    _(form.press(:ctrl_o, "\x0f")).must_equal :start_and_attach
    other = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false))
    type_into(other, "do it")
    _(other.press(:ctrl_s, "\x13")).must_equal :start
  end

  def type_into(f, str) = str.each_char { |c| f.press((c == " ") ? :space : c, c) }

  it "goes busy on ^S and ignores keys until the App reports back" do
    type("do it")
    _(form.press(:ctrl_s, "\x13")).must_equal :start
    _(form.footer).must_include "starting session…"
    _(form.press("x", "x")).must_equal :changed
    _(form.values[:prompt]).must_equal "do it"
  end

  it "hands the prompt back with the failure once the App reports it failed" do
    type("do it")
    form.press(:ctrl_s, "\x13")
    form.submission_failed("claude --bg failed: not a trusted directory")
    _(form.footer).must_include "not a trusted directory"
    _(form.values[:prompt]).must_equal "do it"
    _(form.press(:ctrl_s, "\x13")).must_equal :start
  end

  describe "images" do
    let(:clip) { ClaudeInbox::Images::Clipboard.new(nil, nil) }
    let(:form) { ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), clipboard: -> { clip }) }

    it "attaches the clipboard's image on an empty paste, as a token in the prompt" do
      clip.image = "/tmp/shot.png"
      type("match ")
      _(form.paste("")).must_equal :changed
      _(form.values[:prompt]).must_equal "match @/tmp/shot.png"
      rows = form.screen(80, 24)
      _(rows.find { |r| r.include?("match") }).must_include "[Image #1]"
    end

    it "attaches it on ^V too, for terminals without bracketed paste" do
      clip.image = "/tmp/shot.png"
      form.press(:ctrl_v, "\x16")
      _(form.values[:prompt]).must_equal "@/tmp/shot.png"
    end

    it "pastes text from the clipboard when that is what is there" do
      clip.text = "fix it"
      form.press(:ctrl_v, "\x16")
      _(form.values[:prompt]).must_equal "fix it"
      clip.text = nil
      form.press(:ctrl_v, "\x16")
      _(form.footer).must_include "nothing on the clipboard"
    end

    it "keeps an image out of the one-line fields" do
      clip.image = "/tmp/shot.png"
      form.press(:tab, "\t")
      form.paste("")
      _(form.footer).must_include "images go in the prompt"
      _(form.values[:name]).must_be_nil
    end

    it "attaches a dropped image file and keeps any other drop as text" do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a b.png", "x")
        type("see ")
        form.paste("#{dir}/a\\ b.png ")
        form.paste(" not #{dir}/nope.txt")
        _(form.values[:prompt]).must_equal "see @#{dir}/a\\ b.png not #{dir}/nope.txt"
      end
    end

    it "pastes multi-line text into the prompt, and flattens it into a one-line field" do
      form.paste("one\r\ntwo\rthree")
      _(form.values[:prompt]).must_equal "one\ntwo\nthree"
      form.press(:tab, "\t")
      form.paste("my\nname")
      _(form.values[:name]).must_equal "my name"
    end
  end

  it "takes a multi-line prompt: enter breaks the line, ^S starts" do
    type("first")
    form.press(:return, "\r")
    type("second")
    _(form.press(:ctrl_s, "\x13")).must_equal :start
    _(form.values[:prompt]).must_equal "first\nsecond"
    rows = form.screen(80, 24)
    box = rows.index { |r| r.include?("first") }
    _(rows[box + 1]).must_include "second"
    _(rows.find { |r| r.include?("Name") }).wont_be_nil
  end

  it "shows the last rows of a long prompt, counting the rest in the border" do
    10.times { |i|
      type("line#{i}")
      form.press(:return, "\r")
    }
    rows = form.screen(80, 21)
    top = rows.index { |r| r.include?("┌") }
    _(rows[top]).must_include "↑ 4 more"
    _(rows[top + 1]).must_include "line4"
    _(rows[top + 6]).must_include "line9"
    _(rows[top + 8]).must_include "└"
  end

  it "shows what the defaults resolve to" do
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", {model: "opus", effortLevel: "high"}.to_json)
      f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
      rows = f.screen(100, 24)
      _(rows.find { |r| r.include?("Model") }).must_include "opus (settings)"
      _(rows.find { |r| r.include?("Effort") }).must_include "high (settings)"
      _(rows.find { |r| r.include?("Permissions") }).must_include "auto (cli default)"
      _(f.values[:model]).must_equal "default"
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
        _(rows.find { |r| r.include?("Model") }).must_include "opus (settings)"
        _(rows.find { |r| r.include?("Permissions") }).must_include "plan (settings)"
      end
    end
  end

  it "starts with Remote Control when settings turn it on for all sessions" do
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
      f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
      _(f.screen(100, 24).find { |r| r.include?("Remote Control") }).must_include "yes (settings)"
      _(f.values[:remote]).must_equal true
      7.times { f.press(:tab, "\t") }
      f.press("l", "l")
      _(f.values[:remote]).must_equal false
    end
  end

  it "leaves Remote Control off when nothing turns it on" do
    Dir.mktmpdir do |home|
      f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false), home: home)
      _(f.values[:remote]).must_equal false
      7.times { f.press(:tab, "\t") }
      f.press("h", "h")
      _(f.values[:remote]).must_equal true
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
      _(form.focused.value.to_s).must_equal "#{root}/banana/"
      form.press(:ctrl_u, "\x15")
      type("#{root}/a")
      form.press(:tab, "\t")
      _(form.focused.value.to_s).must_equal "#{root}/ap"
      _(form.footer).must_include "apple  apricot"
      form.press(:tab, "\t")
      _(form.focused.key).must_equal :cwd
      _(form.footer).must_include "apple  apricot"
      type("pl")
      form.press(:tab, "\t")
      _(form.focused.value.to_s).must_equal "#{root}/apple/"
      form.press(:tab, "\t")
      _(form.focused.key).must_equal :model
    end
  end

  it "edits the prompt under the cursor, and still cycles choices with arrows" do
    type("abd")
    form.press(:left, "\e[D")
    type("c")
    _(form.values[:prompt]).must_equal "abcd"
    form.press(:backspace, "\x7f")
    form.press(:home, "\e[H")
    type("A")
    _(form.values[:prompt]).must_equal "Aabd"
    3.times { form.press(:tab, "\t") }
    form.press(:right, "\e[C")
    _(form.values[:model]).must_equal "fable"
  end

  it "draws the cursor on the cell it sits on" do
    f = ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: true))
    "ab".each_char { |c| f.press(c, c) }
    f.press(:left, "\e[D")
    _(f.screen(80, 24).join("\n")).must_include "a\e[7mb\e[0m"
  end

  it "cancels on escape when the prompt is empty" do
    _(form.press(:escape, "\e")).must_equal :cancel
  end

  it "asks to confirm on escape once the prompt has text, then honors the answer" do
    form.press("h", "h")
    _(form.press(:escape, "\e")).must_equal :changed
    _(form.screen(80, 24).join("\n")).must_include "Discard this session?"
    _(form.footer).must_include "discard"
    _(form.press("n", "n")).must_equal :changed
    _(form.screen(80, 24).join("\n")).must_include "New session"
    _(form.press(:escape, "\e")).must_equal :changed
    _(form.press("y", "y")).must_equal :cancel
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
        _(f.menu.map(&:name)).must_equal %w[babysit deploy unslop unsplit]
        _(f.footer).must_include "pick"
        type(f, "uns")
        _(f.menu.map(&:name)).must_equal %w[unslop unsplit]
        rows = f.screen(80, 24)
        _(rows.find { |r| r.include?("/unsplit") }).must_include "unsplit does things"
        _(rows.find { |r| r.include?("/unslop") }).wont_be_nil
        _(rows.find { |r| r.include?("Worktree") }).wont_be_nil
        type(f, "zz")
        _(f.menu).must_be_nil
      end
    end

    it "picks with tab or enter, leaving the cursor after the command and a space" do
      with_commands do |f|
        type(f, "/unsl")
        _(f.press(:tab, "\t")).must_equal :changed
        _(f.values[:prompt]).must_equal "/unslop"
        _(f.focused.value.to_s).must_equal "/unslop "
        _(f.menu).must_be_nil
        type(f, "the readme")
        _(f.press(:return, "\r")).must_equal :changed
        type(f, "/dep")
        _(f.menu.map(&:name)).must_equal %w[deploy]
        f.press(:return, "\r")
        _(f.values[:prompt]).must_equal "/unslop the readme\n/deploy"
      end
    end

    it "moves the pick with the arrows and keeps enter for picking" do
      with_commands do |f|
        type(f, "/")
        f.press(:down, "\e[B")
        _(f.picked.name).must_equal "deploy"
        f.press(:up, "\e[A")
        f.press(:up, "\e[A")
        _(f.picked.name).must_equal "unsplit"
        f.press(:return, "\r")
        _(f.values[:prompt]).must_equal "/unsplit"
        _(f.focused.key).must_equal :prompt
      end
    end

    it "closes the menu on escape without leaving the form, until the query changes" do
      with_commands do |f|
        type(f, "/un")
        _(f.press(:escape, "\e")).must_equal :changed
        _(f.menu).must_be_nil
        _(f.press(:tab, "\t")).must_equal :changed
        _(f.focused.key).must_equal :name
        f.press(:back_tab, "\e[Z")
        _(f.menu).must_be_nil
        type(f, "s")
        _(f.menu.map(&:name)).must_equal %w[unslop unsplit]
        _(f.press(:escape, "\e")).must_equal :changed
        _(f.press(:escape, "\e")).must_equal :changed
        _(f.footer).must_include "discard"
      end
    end

    it "offers commands for a slash word anywhere in the prompt, but not mid-word" do
      with_commands do |f|
        type(f, "first do")
        f.press(:return, "\r")
        type(f, "then /uns")
        _(f.menu.map(&:name)).must_equal %w[unslop unsplit]
        f.press(:tab, "\t")
        _(f.values[:prompt]).must_equal "first do\nthen /unslop"
        type(f, "a/b")
        _(f.menu).must_be_nil
        f.press(:ctrl_u, "\x15")
        type(f, "/unslop x")
        _(f.menu).must_be_nil
        f.press(:left, "\e[D")
        f.press(:left, "\e[D")
        _(f.menu.map(&:name)).must_equal %w[unslop]
        f.press(:tab, "\t")
        _(f.focused.value.to_s).must_equal "/unslop  x"
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
        _(rows.count { |r| r.include?("/cmd-") }).must_equal 6
        _(rows.find { |r| r.include?("/cmd-f") }).must_include "+4 more"
        7.times { f.press(:down, "\e[B") }
        rows = f.screen(80, 24)
        _(rows.find { |r| r.include?("/cmd-b") }).must_be_nil
        _(rows.find { |r| r.include?("/cmd-c") }).wont_be_nil
        _(rows.find { |r| r.include?("/cmd-h") }).must_include "+2 more"
      end
    end
  end
end
