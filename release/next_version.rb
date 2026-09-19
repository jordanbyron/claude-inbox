# frozen_string_literal: true

module Release
  # The semver bump the conventional commits since the last release call for,
  # applied to the version they were made on. Nothing to release is a nil.
  class NextVersion
    SUBJECT = /\A\w+(?:\([^)]*\))?(?<breaking>!)?:/
    BREAKING_FOOTER = /^BREAKING[ -]CHANGE:/

    def initialize(current, messages)
      @current = current
      @messages = messages
    end

    def bump
      kinds = @messages.map { |message| kind(message) }
      if kinds.include?(:major)
        # Semver's 0.x rule: nothing is stable yet, so breaking changes bump minor.
        @current.start_with?("0.") ? :minor : :major
      elsif kinds.include?(:minor)
        :minor
      elsif kinds.include?(:patch)
        :patch
      end
    end

    def version
      major, minor, patch = @current.split(".").map(&:to_i)
      case bump
      when :major then "#{major + 1}.0.0"
      when :minor then "#{major}.#{minor + 1}.0"
      when :patch then "#{major}.#{minor}.#{patch + 1}"
      end
    end

    private

    def kind(message)
      subject = message.lines.first.to_s
      return :major if subject[SUBJECT, :breaking] || message.match?(BREAKING_FOOTER)

      case subject[/\A(\w+)/]
      when "feat" then :minor
      when "fix" then :patch
      end
    end
  end
end
