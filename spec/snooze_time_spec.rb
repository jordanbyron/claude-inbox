# frozen_string_literal: true

RSpec.describe ClaudeInbox::SnoozeTime do
  # A Wednesday evening.
  let(:now) { Time.new(2026, 9, 16, 20, 30, 0) }
  let(:parse) { ->(text, at = now) { described_class.parse(text, at) } }

  it "adds a duration in minutes, hours or days" do
    expect(parse.call("45m")).to eq(now.to_i + 45 * 60)
    expect(parse.call("2h")).to eq(now.to_i + 2 * 3600)
    expect(parse.call("3d")).to eq(now.to_i + 3 * 86_400)
    expect(parse.call(" 90 min ")).to eq(now.to_i + 90 * 60)
    expect(parse.call("1 hour")).to eq(now.to_i + 3600)
  end

  it "takes a clock time as the next such time" do
    expect(parse.call("21:15")).to eq(Time.new(2026, 9, 16, 21, 15).to_i)
    expect(parse.call("17:00")).to eq(Time.new(2026, 9, 17, 17, 0).to_i)
    expect(parse.call("5pm")).to eq(Time.new(2026, 9, 17, 17, 0).to_i)
    expect(parse.call("9:30 AM")).to eq(Time.new(2026, 9, 17, 9, 30).to_i)
    expect(parse.call("12am")).to eq(Time.new(2026, 9, 17, 0, 0).to_i)
    expect(parse.call("12pm")).to eq(Time.new(2026, 9, 17, 12, 0).to_i)
  end

  it "takes a weekday as that day at 9am, a week on once it has passed" do
    expect(parse.call("fri")).to eq(Time.new(2026, 9, 18, 9).to_i)
    expect(parse.call("Friday")).to eq(Time.new(2026, 9, 18, 9).to_i)
    expect(parse.call("wed")).to eq(Time.new(2026, 9, 23, 9).to_i)
    expect(parse.call("wed", Time.new(2026, 9, 16, 8))).to eq(Time.new(2026, 9, 16, 9).to_i)
    expect(parse.call("sun 5pm")).to eq(Time.new(2026, 9, 20, 17).to_i)
  end

  it "takes tomorrow, with 9am unless a time follows" do
    expect(parse.call("tomorrow")).to eq(Time.new(2026, 9, 17, 9).to_i)
    expect(parse.call("tomorrow 14:00")).to eq(Time.new(2026, 9, 17, 14).to_i)
    expect(parse.call("tomorrow", Time.new(2026, 9, 30, 3))).to eq(Time.new(2026, 10, 1, 9).to_i)
  end

  it "takes tonight or evening as the next 6pm" do
    expect(parse.call("tonight")).to eq(Time.new(2026, 9, 17, 18).to_i)
    expect(parse.call("evening", Time.new(2026, 9, 16, 11))).to eq(Time.new(2026, 9, 16, 18).to_i)
  end

  it "keeps the clock's own offset" do
    utc = Time.new(2026, 9, 16, 20, 30, 0, "+00:00")
    expect(parse.call("tomorrow", utc)).to eq(Time.new(2026, 9, 17, 9, 0, 0, "+00:00").to_i)
  end

  it "reads nothing else" do
    ["", "soon", "0m", "5", "25:00", "9:60", "13pm", "0am", "2h later", "tonight 8pm", "fri at 5", "never"].each do |text|
      expect(parse.call(text)).to be_nil, "#{text.inspect} parsed"
    end
  end
end
