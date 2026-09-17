# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/new_session_form"

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
    _(form.press(:return, "\r")).must_equal :changed
    _(form.lines(60).last).must_include "a prompt is required"
  end

  it "refuses a missing directory" do
    type("do it")
    2.times { form.press(:tab, "\t") }
    form.press(:ctrl_u, "\x15")
    type("/nope/nowhere")
    _(form.press(:return, "\r")).must_equal :changed
    _(form.lines(60).last).must_include "no such directory"
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

  it "cancels on escape" do
    _(form.press(:escape, "\e")).must_equal :cancel
  end
end
