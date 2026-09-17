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
end

describe ClaudeInbox::NewSessionForm do
  let(:form) { ClaudeInbox::NewSessionForm.new(cwd: Dir.pwd, pastel: Pastel.new(enabled: false)) }

  def type(str) = str.each_char { |c| form.press(c, c) }

  it "starts on the prompt and types into it, spaces included" do
    _(form.focused.key).must_equal :prompt
    "fix the".each_char { |c| form.press(c == " " ? :space : c, c) }
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
    _(form.press(:return, "\r")).must_equal :changed
    _(form.footer).must_include "no such directory"
    form.press(:tab, "\t")
    _(form.focused.key).must_equal :model
  end

  it "submits with expanded values" do
    type("do it")
    6.times { form.press(:tab, "\t") }
    form.press(:space, " ")
    _(form.press(:return, "\r")).must_equal :submit
    v = form.values
    _(v[:worktree]).must_equal true
    _(v[:name]).must_be_nil
    _(v[:cwd]).must_equal Dir.pwd
  end

  it "takes a multi-line prompt: enter breaks the line, ^S starts" do
    type("first")
    form.press(:return, "\r")
    type("second")
    _(form.press(:ctrl_s, "\x13")).must_equal :submit
    _(form.values[:prompt]).must_equal "first\nsecond"
    rows = form.screen(80, 24)
    box = rows.index { |r| r.include?("first") }
    _(rows[box + 1]).must_include "second"
    _(rows.find { |r| r.include?("Name") }).wont_be_nil
  end

  it "shows the last rows of a long prompt" do
    10.times { |i| type("line#{i}"); form.press(:return, "\r") }
    rows = form.screen(80, 20)
    first = rows.index { |r| r.include?("more") }
    _(rows[first]).must_include "line4"
    _(rows[first + 5]).must_include "line9"
    _(rows[first + 6]).must_include "▏"
    _(rows[first + 7]).must_include "└"
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

  it "tab-completes the directory" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/apple")
      FileUtils.mkdir_p("#{root}/apricot")
      FileUtils.mkdir_p("#{root}/banana")
      2.times { form.press(:tab, "\t") }
      form.press(:ctrl_u, "\x15")
      type("#{root}/b")
      form.press(:tab, "\t")
      _(form.focused.value).must_equal "#{root}/banana/"
      form.press(:ctrl_u, "\x15")
      type("#{root}/a")
      form.press(:tab, "\t")
      _(form.focused.value).must_equal "#{root}/ap"
      _(form.footer).must_include "apple  apricot"
      form.press(:tab, "\t")
      _(form.focused.key).must_equal :cwd
      _(form.footer).must_include "apple  apricot"
      type("pl")
      form.press(:tab, "\t")
      _(form.focused.value).must_equal "#{root}/apple/"
      form.press(:tab, "\t")
      _(form.focused.key).must_equal :model
    end
  end

  it "cancels on escape" do
    _(form.press(:escape, "\e")).must_equal :cancel
  end
end
