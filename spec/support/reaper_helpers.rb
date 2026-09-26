# frozen_string_literal: true

# Sessions long enough idle to reap, the store that holds them, and the audit
# log a sweep writes. Uses the group's `now`, `quiet_since`, `client` and
# `log_path`.
module ReaperHelpers
  # merge_entries dates a finished session with no process from `started_at`,
  # so an old `started_at` is the whole of the setup needed to look long idle.
  def quiet_session(id, **attrs) = session(id: id, state: "done", started_at: Time.at(quiet_since), **attrs)

  def store_for(sessions)
    store = ClaudeInbox::Store.new(path: nil, clock: -> { now })
    store.update(sessions)
    store
  end

  def log = File.exist?(log_path) ? File.read(log_path) : ""

  def sweep(store, sessions, at: now) = ClaudeInbox::Reaper.new(client, store, log_path: log_path).sweep(sessions, at)
end

RSpec.configure { |config| config.include ReaperHelpers, :reaper }
