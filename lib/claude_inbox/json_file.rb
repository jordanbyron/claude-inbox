# frozen_string_literal: true

require "json"
require "fileutils"

module ClaudeInbox
  # JSON on disk, written atomically: to a temp file beside the target, then
  # renamed over it, so a reader never sees half a file.
  module JsonFile
    module_function

    def write(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.tmp")
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, path)
    end
  end
end
