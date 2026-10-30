# frozen_string_literal: true

RSpec.describe ClaudeInbox::Titler do
  let(:calls) { [] }
  let(:answer) { ["Comma3x Boot Loop\n", "", true] }
  let(:run) do
    ->(*argv, input:) {
      calls << [argv, input]
      ClaudeInbox::Subprocess::Result.new(answer[0], answer[1], instance_double(Process::Status, success?: answer[2]))
    }
  end
  let(:said) { [["user", "why won't it boot"], ["assistant", "the panda firmware   was stale, reflashing"]] }
  let(:transcript) { instance_double(ClaudeInbox::Transcript, last_messages: said) }
  let(:job) { ClaudeInbox::JobState.new("state" => "done", "intent" => "why won't   my comma3x boot", "output" => {"result" => "the panda firmware was stale"}) }
  let(:row) { session(name: "comma3x not booting", state: "done", job_state: job) }

  subject(:titler) { described_class.new(run: run, transcript: transcript) }

  it "asks claude -p, tools off, from the prompt, the outcome, the latest messages and the current title" do
    expect(titler.title(row, current: "comma3x not booting")).to eq("comma3x boot loop")
    argv, input = calls.first
    expect(argv).to eq(["claude", "-p", "--model", "haiku", "--tools", "", "--no-session-persistence"])
    expect(input).to include('labelled "comma3x not booting" so far')
    expect(input).to include("User: \"why won't my comma3x boot\"")
    expect(input).to include("Agent: \"the panda firmware was stale\"")
    expect(input).to include("USER: \"why won't it boot\"\nASSISTANT: \"the panda firmware was stale, reflashing\"")
    expect(input).to include("Keep the current label if it still fits")
    expect(transcript).to have_received(:last_messages).with(row, count: described_class::MESSAGES)
  end

  it "leaves the messages out of the prompt when the transcript has none" do
    said.clear
    titler.title(row, current: "x")
    expect(calls.first[1]).not_to include("Latest messages")
  end

  it "takes the quotes and the full stop off a label that came dressed up" do
    answer.replace(["“Panda firmware refresh.”\n", "", true])
    expect(titler.title(row, current: "x")).to eq("panda firmware refresh")
  end

  it "refuses an answer that talks instead of labelling" do
    answer.replace(["I'm sorry, I can't tell what this job is about.", "", true])
    expect { titler.title(row, current: "x") }.to raise_error(described_class::Error, /answered “i'm sorry, i can't tell what this job is” rather than a title/)
  end

  it "refuses a label that runs past five words" do
    answer.replace(["one two three four five six", "", true])
    expect { titler.title(row, current: "x") }.to raise_error(described_class::Error, /rather than a title/)
  end

  it "reports a failed run by its last line of stderr" do
    answer.replace(["", "warning: something\nNot logged in\n", false])
    expect { titler.title(row, current: "x") }.to raise_error(described_class::Error, "claude -p failed: Not logged in")
  end

  it "has nothing to ask about a session with no prompt, outcome or messages on record" do
    said.clear
    expect { titler.title(session(job_state: nil), current: "x") }.to raise_error(described_class::Error, "nothing on record to title it from")
    expect(calls).to be_empty
  end
end
