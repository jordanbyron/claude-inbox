# frozen_string_literal: true

require "json"
require "fileutils"

module ClaudeInbox
  # The inbox's own records — the snooze table, the resolved PRs — kept
  # under ~/.config/claude-inbox between launches. Saved atomically (a temp
  # file beside the target, renamed over it) so a poll mid-write never
  # reads half a record.
  module Records
    module_function

    def save(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.tmp")
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, path)
    end
  end
end
