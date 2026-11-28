# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::WriterLock do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "writer.lock") }

  after { FileUtils.remove_entry(dir) }

  it "is held by one taker at a time" do
    first = described_class.new(path: path)
    second = described_class.new(path: path)
    expect(first.take(role: "headless")).to be(true)
    expect(File.read(path)).to eq("headless #{Process.pid}")
    expect(second.take(role: "headless")).to be(false)
  end

  it "never evicts an inbox: a second inbox runs without the lock" do
    first = described_class.new(path: path)
    expect(first.take(role: "inbox")).to be(true)
    expect(described_class.new(path: path).take(role: "inbox")).to be(false)
    expect(described_class.new(path: path).take(role: "headless")).to be(false)
    expect(File.read(path)).to eq("inbox #{Process.pid}")
  end

  it "takes over from a headless holder that is gone" do
    File.write(path, "headless 999999999")
    expect(described_class.new(path: path).take(role: "inbox")).to be(true)
    expect(File.read(path)).to eq("inbox #{Process.pid}")
  end

  it "ends a headless claude-inbox that holds the lock" do
    holder = <<~RUBY
      f = File.open(ARGV[0], File::RDWR | File::CREAT)
      f.flock(File::LOCK_EX)
      f.write("headless \#{Process.pid}")
      f.flush
      sleep
    RUBY
    pid = Process.spawn("ruby", "-e", holder, path, "claude-inbox", "--headless")
    expect(wait_for(timeout: 5) { File.exist?(path) && File.read(path) == "headless #{pid}" }).to be(true)
    expect(described_class.new(path: path).take(role: "inbox")).to be(true)
    status = nil
    wait_for { status ||= Process.wait2(pid, Process::WNOHANG)&.last }
    expect(status&.termsig).to eq(Signal.list["TERM"])
    expect(File.read(path)).to eq("inbox #{Process.pid}")
  ensure
    if pid && status.nil?
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  it "never signals a pid the file names that is not a headless claude-inbox" do
    held = File.open(path, File::RDWR | File::CREAT)
    held.flock(File::LOCK_EX)
    bystander = Process.spawn("sleep", "30")
    File.write(path, "headless #{bystander}")
    expect(described_class.new(path: path).take(role: "inbox")).to be(false)
    expect(Process.waitpid(bystander, Process::WNOHANG)).to be_nil
  ensure
    Process.kill("KILL", bystander) if bystander
    held&.close
  end

  it "is always held when disabled" do
    expect(described_class.disabled.take(role: "inbox")).to be(true)
  end
end
