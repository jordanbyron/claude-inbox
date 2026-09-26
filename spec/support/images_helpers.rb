# frozen_string_literal: true

# Subprocess results and aged files for the Images spec.
module ImagesHelpers
  def result(out, ok) = ClaudeInbox::Subprocess::Result.new(out, "", Struct.new(:success?).new(ok))

  def touch(dir, name, mtime: Time.now)
    File.join(dir, name).tap { |f|
      File.write(f, "x")
      File.utime(mtime, mtime, f)
    }
  end
end

RSpec.configure { |config| config.include ImagesHelpers, :images }
