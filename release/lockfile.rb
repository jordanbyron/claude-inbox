# frozen_string_literal: true

module Release
  # Gemfile.lock's record of the gem's own version. Bundler copies it from the
  # gemspec, so a release that bumps VERSION has to relock or the next
  # `bundle install` rewrites the lock and dirties the tree.
  class Lockfile
    OWN_SPEC = /^    claude-inbox \((?<version>[^)]+)\)$/

    # bin/release may itself run under Bundler, whose setup would otherwise
    # pin the child to the Gemfile it was started with.
    UNBUNDLED = %w[BUNDLE_LOCKFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION RUBYOPT].to_h { [it, nil] }

    def initialize(dir)
      @dir = dir
    end

    def version = File.read(File.join(@dir, "Gemfile.lock"))[OWN_SPEC, :version]

    def sync
      env = UNBUNDLED.merge("BUNDLE_GEMFILE" => File.join(@dir, "Gemfile"))
      system(env, "bundle", "lock", "--local", chdir: @dir, out: File::NULL)
    end
  end
end
