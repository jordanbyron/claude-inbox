# frozen_string_literal: true

require "rbconfig"
require "tmpdir"

RSpec.describe ClaudeInbox::Antigravity::ConversationsClient do
  let(:sessions) { ClaudeInbox::Antigravity::FixtureClient.new(fixture_path("antigravity-conversations.json")).list }

  it "reads each fixture conversation as a background session to attach to or stop, never delete" do
    working, idle = sessions
    expect(sessions.map(&:harness).uniq).to eq([:antigravity])
    expect(working).to have_attributes(
      id: "9f2a1c4e-7b3d-4e8a-9c10-3d5e6f7a8b9c",
      kind: "background",
      cwd: "/Users/byron/code/claude-inbox",
      name: "Add Antigravity harness adapter",
      intent: "Wire agy conversations into the inbox alongside Claude and Codex",
      state: "working",
      started_at: Time.parse("2026-09-16 21:10:00+00:00"),
      last_message_at: Time.parse("2026-09-16 21:30:00+00:00"),
      actions: %i[attach stop],
      pid: nil
    )
    expect(working).to be_attachable
    expect(working.can?(:delete)).to be(false)
    expect(idle).to have_attributes(
      id: "4e8b2d1a-5c6f-4a90-8b21-1f2e3d4c5b6a",
      cwd: "/Users/byron/code/parks_genie",
      name: "Audit the staging backup retention policy and report gaps",
      intent: "Audit the staging backup retention policy and report gaps",
      state: "idle"
    )
  end

  it "decodes workspace file URIs, skipping non-file entries, and falls back to the id when nameless" do
    row = {
      "conversation_id" => "c1",
      "title" => "",
      "preview" => "   ",
      "workspace_uris" => JSON.generate(["https://example.com/repo", "file:///Users/x/c++%20proj"]),
      "status" => "CASCADE_RUN_STATUS_IDLE",
      "last_modified_time" => "2026-11-21 18:27:27.912563+00:00",
      "last_user_input_time" => ""
    }
    s = described_class.session(row)
    expect(s.cwd).to eq("/Users/x/c++ proj")
    expect(s.name).to be_nil
    expect(s.intent).to be_nil
    expect(s.display_name).to eq("c1")
    expect(s.started_at).to eq(s.last_message_at)
  end

  it "parses models from agy models output and ignores headers and errors" do
    out = <<~TXT
      Fetching available models...
      gemini-4-neon-high\tGemini 4 Neon (High)
      gemini-4-neon-low\tGemini 4 Neon (Low)
    TXT
    expect(described_class.parse_models(out)).to eq(%w[gemini-4-neon-high gemini-4-neon-low])
    expect(described_class.parse_models("Fetching available models...\nError: not signed in\n")).to eq([])
  end

  describe "against a real WAL-mode SQLite database" do
    let(:dir) { Dir.mktmpdir("agy") }
    let(:db) { File.join(dir, "conversation_summaries.db") }
    let(:presence) { File.join(dir, "presence").tap { |d| FileUtils.mkdir_p(d) } }
    let(:now) { Time.parse("2026-11-21 19:00:00+00:00") }
    let(:fake_agy) do
      File.join(dir, "agy").tap do |path|
        File.write(path, <<~SH)
          #!/bin/sh
          if [ "$1" = "models" ]; then
            echo "Fetching available models..."
            printf "gemini-4-neon-high\\tGemini 4 Neon (High)\\n"
            printf "gemini-4-neon-low\\tGemini 4 Neon (Low)\\n"
            echo "models" >> "$0.calls"
            exit 0
          fi
        SH
        File.chmod(0o755, path)
      end
    end
    let(:client) { described_class.new(dir: dir, bin: fake_agy, clock: -> { now }) }
    let(:sql) do
      lambda do |statements|
        ok = system("sqlite3", db, statements, out: File::NULL, err: File::NULL)
        raise "sqlite3 failed" unless ok
      end
    end

    before do
      sql.call(<<~SQL)
        PRAGMA journal_mode=WAL;
        CREATE TABLE conversation_summaries (
          conversation_id TEXT PRIMARY KEY,
          title TEXT,
          preview TEXT,
          step_count INTEGER,
          last_modified_time TEXT,
          last_user_input_time TEXT,
          workspace_uris TEXT,
          status TEXT,
          parent_conversation_id TEXT,
          not_fully_idle INTEGER,
          killed INTEGER,
          project_id TEXT,
          agent_name TEXT
        );
        INSERT INTO conversation_summaries VALUES
          ('live', 'Live run', 'do live work', 3, '2026-11-21 18:55:00+00:00', '2026-11-21 18:50:00+00:00', '["file:///tmp/a"]', 'CASCADE_RUN_STATUS_RUNNING', '', 1, 0, '', ''),
          ('stale', 'Hard killed', 'crashed work', 2, '2026-11-21 18:40:00+00:00', '2026-11-21 18:35:00+00:00', '["file:///tmp/b"]', 'CASCADE_RUN_STATUS_RUNNING', '', 1, 0, '', ''),
          ('sub', 'Subagent', 'sub work', 1, '2026-11-21 18:59:00+00:00', '2026-11-21 18:59:00+00:00', '["file:///tmp/a"]', 'CASCADE_RUN_STATUS_RUNNING', 'live', 1, 0, '', ''),
          ('old', 'Ancient', 'old work', 1, '2026-10-01 00:00:00+00:00', '2026-10-01 00:00:00+00:00', '["file:///tmp/c"]', 'CASCADE_RUN_STATUS_IDLE', '', 0, 0, '', '');
        PRAGMA wal_checkpoint(TRUNCATE);
      SQL
      FileUtils.rm_f(["#{db}-wal", "#{db}-shm"])
    end

    after { FileUtils.remove_entry(dir) }

    it "lists top-level recent conversations without creating -wal/-shm, and treats unlocked RUNNING rows as idle" do
      lock_file = File.join(presence, "live.lock")
      File.write(lock_file, "")
      File.write(File.join(presence, "stale.lock"), "")
      holder = File.open(lock_file, File::RDWR)
      holder.flock(File::LOCK_EX | File::LOCK_NB)
      expect(client).not_to receive(:holder_pids)

      listed = client.list
      expect(listed.map(&:id)).to eq(%w[live stale])
      expect(listed.map(&:state)).to eq(%w[working idle])
      expect(File.exist?("#{db}-wal")).to be(false)
      expect(File.exist?("#{db}-shm")).to be(false)
    ensure
      holder&.close
    end

    it "treats an IDLE row with a held lock as working when the holder is headless, and idle when interactive" do
      sql.call("UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE' WHERE conversation_id = 'live'; PRAGMA wal_checkpoint(TRUNCATE);")
      FileUtils.rm_f(["#{db}-wal", "#{db}-shm"])
      lock_file = File.join(presence, "live.lock")
      File.write(lock_file, "")
      holder = File.open(lock_file, File::RDWR)
      holder.flock(File::LOCK_EX | File::LOCK_NB)

      %w[-p --print --prompt].each do |flag|
        allow(client).to receive(:commands_for).with([Process.pid]).and_return(["/opt/homebrew/bin/agy #{flag} fix it --output-format stream-json"])
        expect(client.list.find { |s| s.id == "live" }.state).to eq("working")
      end

      allow(client).to receive(:commands_for).with([Process.pid]).and_return(["/opt/homebrew/bin/agy --conversation live"])
      expect(client.list.find { |s| s.id == "live" }.state).to eq("idle")
    ensure
      holder&.close
    end

    it "keeps fresh placeholder rows with year-1 timestamps, using the lock file's mtime when present" do
      sql.call(<<~SQL)
        INSERT INTO conversation_summaries VALUES
          ('fresh', '', '', 0, '0001-01-01 00:00:00+00:00', '0001-01-01 00:00:00+00:00', '["file:///tmp/probe"]', 'CASCADE_RUN_STATUS_RUNNING', '', 1, 0, '', ''),
          ('nolock', '', '', 0, '0001-01-01 00:00:00+00:00', '0001-01-01 00:00:00+00:00', '["file:///tmp/probe"]', 'CASCADE_RUN_STATUS_IDLE', '', 0, 0, '', '');
        PRAGMA wal_checkpoint(TRUNCATE);
      SQL
      FileUtils.rm_f(["#{db}-wal", "#{db}-shm"])

      lock_file = File.join(presence, "fresh.lock")
      File.write(lock_file, "")
      lock_time = Time.parse("2026-11-21 18:59:30+00:00")
      File.utime(lock_time, lock_time, lock_file)
      holder = File.open(lock_file, File::RDWR)
      holder.flock(File::LOCK_EX | File::LOCK_NB)

      listed = client.list
      expect(listed.map(&:id)).to eq(%w[fresh live stale nolock])
      fresh = listed.first
      expect(fresh).to have_attributes(
        state: "working",
        name: nil,
        display_name: "fresh",
        started_at: lock_time,
        last_message_at: lock_time
      )
      expect(listed.last).to have_attributes(id: "nolock", state: "idle", started_at: nil, last_message_at: nil)
    ensure
      holder&.close
    end

    it "reads uncommitted WAL writes while another process holds the database open" do
      r, w = IO.pipe
      pid = Process.spawn("sqlite3", db, in: r, out: File::NULL, err: File::NULL)
      r.close
      w.puts("INSERT INTO conversation_summaries VALUES ('walrow', 'In WAL', 'fresh', 1, '2026-11-21 18:58:00+00:00', '2026-11-21 18:58:00+00:00', '[\"file:///tmp/w\"]', 'CASCADE_RUN_STATUS_IDLE', '', 0, 0, '', '');")
      w.flush
      expect(wait_for { File.exist?("#{db}-wal") && File.size("#{db}-wal") > 0 }).to be(true)

      expect(client.list.map(&:id)).to eq(%w[walrow live stale])
    ensure
      w&.close
      Process.wait(pid) if pid
    end

    it "returns an empty list without raising when the database, sqlite3 or fixture is missing" do
      expect(described_class.new(dir: File.join(dir, "missing"), bin: "/nonexistent/agy").list).to eq([])
      expect(described_class.new(dir: dir, sqlite: "/nonexistent/sqlite3", bin: "/nonexistent/agy").list).to eq([])
      expect(ClaudeInbox::Antigravity::FixtureClient.new("/nonexistent/antigravity.json").list).to eq([])
    end

    it "moves pulse when the database or its WAL changes" do
      before = client.pulse
      expect(client.pulse).to eq(before)
      File.write("#{db}-wal", "x")
      expect(client.pulse).not_to eq(before)
      expect(described_class.new(dir: File.join(dir, "missing")).pulse).to eq([nil, nil])
    end

    it "fills choices once during list, and leaves them empty when agy is missing or signed out" do
      expect(client.choices).to eq({})
      2.times { client.list }
      expect(client.choices).to eq(model: %w[default gemini-4-neon-high gemini-4-neon-low])
      expect(File.readlines("#{fake_agy}.calls").size).to eq(1)

      signed_out = File.join(dir, "signed-out")
      File.write(signed_out, "#!/bin/sh\necho 'Error: not signed in'\nexit 1\n")
      File.chmod(0o755, signed_out)
      out_client = described_class.new(dir: File.join(dir, "no-db"), bin: signed_out)
      out_client.list
      expect(out_client.choices).to eq({})

      missing = described_class.new(dir: File.join(dir, "no-db"), bin: "/nonexistent/agy")
      missing.list
      expect(missing.choices).to eq({})
    end
  end

  describe "acting on a conversation" do
    let(:dir) { Dir.mktmpdir("agy-act") }
    let(:presence) { File.join(dir, "presence").tap { |d| FileUtils.mkdir_p(d) } }
    let(:conv) { session(harness: :antigravity, actions: described_class::ACTIONS, id: "conv-1", cwd: dir) }

    after { FileUtils.remove_entry(dir) }

    it "attaches in the conversation's directory and honours the early-stop block" do
      bin = File.join(dir, "agy")
      File.write(bin, "#!/bin/sh\necho \"$PWD $*\" > \"$0.log\"\n")
      File.chmod(0o755, bin)
      expect(described_class.new(dir: dir, bin: bin).attach(conv)).to be(true)
      expect(File.read("#{bin}.log")).to eq("#{File.realpath(dir)} --conversation conv-1\n")

      fail_bin = File.join(dir, "agy-fail")
      File.write(fail_bin, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, fail_bin)
      expect(described_class.new(dir: dir, bin: fail_bin).attach(conv)).to be(false)

      slow_bin = File.join(dir, "agy-slow")
      File.write(slow_bin, "#!/bin/sh\nsleep 30\n")
      File.chmod(0o755, slow_bin)
      calls = 0
      expect(described_class.new(dir: dir, bin: slow_bin).attach(conv) { (calls += 1) >= 2 }).to be(true)
    end

    it "sends SIGINT to the process holding the presence lock, and returns false when nobody holds it" do
      client = described_class.new(dir: dir)
      expect(client.stop(conv)).to be(false)

      lock = File.join(presence, "conv-1.lock")
      ready = File.join(dir, "ready")
      got_int = File.join(dir, "got-int")
      pid = Process.spawn(RbConfig.ruby, "-e", <<~RB, lock, ready, got_int)
        f = File.open(ARGV[0], File::CREAT | File::RDWR)
        f.flock(File::LOCK_EX)
        Signal.trap("INT") do
          File.write(ARGV[2], "interrupted")
          exit 0
        end
        File.write(ARGV[1], Process.pid.to_s)
        sleep 30
      RB
      expect(wait_for { File.exist?(ready) }).to be(true)
      expect(client.stop(conv)).to be(true)
      expect(wait_for { File.exist?(got_int) }).to be(true)
      Process.wait(pid)

      expect(client.stop(conv)).to be(false)
    end

    it "refuses rm with Harnesses::Error" do
      expect { described_class.new(dir: dir).rm(conv) }.to raise_error(ClaudeInbox::Harnesses::Error, /cannot be deleted/)
      expect { ClaudeInbox::Antigravity::FixtureClient.new("/nonexistent").rm(conv) }.to raise_error(ClaudeInbox::Harnesses::Error)
    end

    it "spawns a detached headless run, returns the init conversation id, and does not block or SIGPIPE later output" do
      done_marker = File.join(dir, "child-done")
      argv_log = File.join(dir, "argv.log")
      bin = File.join(dir, "agy")
      File.write(bin, <<~RB)
        #!#{RbConfig.ruby}
        File.write(#{argv_log.inspect}, [Dir.pwd, *ARGV].join("\\n"))
        $stdout.sync = true
        puts '{"event":"init","conversation_id":"conv-99","init":{"model":"gemini-4-neon-high"}}'
        sleep 0.05
        # Write well past a 64KB pipe buffer after the caller has stopped reading.
        1000.times { puts '{"event":"chunk","text":"#{"x" * 200}"}' }
        puts '{"event":"result","status":"OK"}'
        File.write(#{done_marker.inspect}, "ok")
      RB
      File.chmod(0o755, bin)

      client = described_class.new(dir: dir, bin: bin)
      expect(client.spawn(prompt: "fix it", cwd: dir, model: "gemini-4-neon-high")).to eq("conv-99")
      expect(wait_for { File.exist?(done_marker) }).to be(true)
      expect(File.read(argv_log).lines.map(&:chomp)).to eq([
        File.realpath(dir), "-p", "fix it", "--model", "gemini-4-neon-high", "--output-format", "stream-json"
      ])

      FileUtils.rm_f(done_marker)
      expect(client.spawn(prompt: "default model", cwd: dir)).to eq("conv-99")
      expect(wait_for { File.exist?(done_marker) }).to be(true)
      expect(File.read(argv_log).lines.map(&:chomp)).to eq([
        File.realpath(dir), "-p", "default model", "--output-format", "stream-json"
      ])
    end

    it "raises Harnesses::Error when spawn fails before init or agy is missing" do
      bin = File.join(dir, "agy-bad")
      File.write(bin, "#!/bin/sh\necho 'Error: not signed in' >&2\nexit 1\n")
      File.chmod(0o755, bin)
      expect { described_class.new(dir: dir, bin: bin).spawn(prompt: "hi", cwd: dir) }
        .to raise_error(ClaudeInbox::Harnesses::Error, /not signed in/)

      expect { described_class.new(dir: dir, bin: "/nonexistent/agy").spawn(prompt: "hi", cwd: dir) }
        .to raise_error(ClaudeInbox::Harnesses::Error)
    end
  end
end
