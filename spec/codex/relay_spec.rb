# frozen_string_literal: true

require "pty"
require "tmpdir"

RSpec.describe ClaudeInbox::Codex::Relay do
  let(:dir) { Dir.mktmpdir }
  let(:log) { File.join(dir, "keys") }
  # Stands in for codex: draws one frame ending with its cursor shown in
  # column $COL, then records every byte it is sent until it is ended.
  let(:codex) do
    File.join(dir, "codex").tap do |bin|
      File.write(bin, <<~SH)
        #!/bin/sh
        stty raw -echo
        echo $$ > "$LOG.pid"
        printf '\\033[5;%sH\\033[?25h' "$COL"
        [ -n "$HIDE" ] && printf '\\033[?25l'
        [ -n "$FAIL" ] && exit "$FAIL"
        exec cat > "$LOG"
      SH
      File.chmod(0o755, bin)
    end
  end
  # The user's terminal: the relay gets the slave end, the spec types into
  # the master end and collects what is drawn there.
  let(:terminal) { PTY.open }
  let(:screen) { +"" }
  let(:relay) do
    lambda do |env = {}, &stop|
      master, slave = terminal
      Thread.new {
        begin
          loop { screen << master.readpartial(4096) }
        rescue
          nil
        end
      }
      Thread.new { described_class.run([{"COL" => "3", "LOG" => log, **env}, codex], tty: slave, out: slave, &stop) }
    end
  end
  let(:press) { ->(keys) { terminal.first.write(keys) } }

  after do
    terminal.each(&:close)
    FileUtils.rm_rf(dir)
  end

  it "leaves on ← with the cursor at the start of Codex's prompt, and ends Codex" do
    run = relay.call
    wait_for { screen.include?("\e[?25h") }
    press.call("\e[D")
    expect(run.join(3)&.value).to be(true)
    pid = File.read("#{log}.pid").to_i
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    expect(screen).to include(described_class::RESET)
  end

  it "leaves on a kitty press that arrives with its release" do
    run = relay.call
    wait_for { screen.include?("\e[?25h") }
    press.call("\e[D\e[1;1:3D")
    expect(run.join(3)&.value).to be(true)
  end

  it "passes ← to Codex when the cursor is anywhere else, or hidden" do
    [{"COL" => "6"}, {"HIDE" => "1"}].each do |env|
      done = false
      run = relay.call(env) { done }
      wait_for { File.exist?(log) }
      press.call("\e[Dx")
      expect(wait_for { File.read(log) == "\e[Dx" }).to be(true)
      done = true
      expect(run.join(3)&.value).to be(true)
      FileUtils.rm_f(log)
    end
  end

  it "reports Codex failing on its own, and not an attach ended by the block" do
    expect(relay.call("FAIL" => "3").join(3)&.value).to be(false)
    expect(relay.call { true }.join(3)&.value).to be(true)
  end
end
