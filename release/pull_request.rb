# frozen_string_literal: true

require "json"

module Release
  # A pull request merged since the last release, as gh reports it, and the
  # label its conventional prefix calls for. GitHub groups the release notes
  # by these labels (.github/release.yml).
  class PullRequest < Data.define(:number, :title, :body, :labels)
    TYPE_LABELS = {"feat" => "enhancement", "fix" => "bug", "refactor" => "refactor", "docs" => "documentation"}.freeze
    FIELDS = "number,title,body,labels"
    IMAGE = /!\[[^\]]*\]\((\S+?)\)|<img\b[^>]*\bsrc="([^"]+)"/

    def self.numbers_in(messages)
      messages.filter_map { |message| message.lstrip.lines.first.to_s[/\(#(\d+)\)\s*\z/, 1] }
    end

    def self.parse(json)
      pull_request = JSON.parse(json)
      new(number: pull_request["number"], title: pull_request["title"], body: pull_request["body"].to_s,
        labels: pull_request["labels"].map { |label| label["name"] })
    end

    def missing_label
      label = TYPE_LABELS[title[/\A(\w+)/]]
      label unless label.nil? || labels.intersect?(TYPE_LABELS.values)
    end

    def feature? = title.match?(/\Afeat\b/)

    def images = body.scan(IMAGE).flatten.compact
  end
end
