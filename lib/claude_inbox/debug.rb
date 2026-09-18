# frozen_string_literal: true

module ClaudeInbox
  # DEBUG=1 appends notes to LOG: slow frames, the attach
  # watchdog. Off, it costs one env lookup.
  module Debug
    LOG = "/tmp/inbox-debug.log"

    module_function

    def log(msg)
      return unless ENV["DEBUG"]
      File.write(LOG, "#{Time.now.strftime("%H:%M:%S.%L")} #{msg}\n", mode: "a")
    end
  end
end
