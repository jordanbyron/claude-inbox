# frozen_string_literal: true

require "json"
require "fileutils"

module ClaudeInbox
  # The inbox's own records — the snooze table, the resolved PRs — kept
  # under ~/.config/claude-inbox between launches. Saved atomically (a temp
  # file beside the target, renamed over it) so a poll mid-write never
  # reads half a record. Reading a missing or unparsable record yields {}
  # so callers start from empty instead of failing.
  module Records
    module_function

    def read(path)
      (path && File.exist?(path)) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end

    # `perm` is set on the temp file before anything is written to it, so
    # a secret is never readable at a wider mode, not even briefly.
    def save(path, data, perm: nil)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.tmp")
      File.open(tmp, "w", perm || 0o666) do |f|
        f.chmod(perm) if perm
        f.write(JSON.pretty_generate(data))
      end
      File.rename(tmp, path)
    end
  end
end
