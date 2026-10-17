# frozen_string_literal: true

module Release
  # The prompt that has claude write the Highlights section opening a
  # release's notes: a heading and a paragraph for each pull request the
  # maintainer picked, with its screenshot where there is one.
  class Highlights
    def initialize(tag, picks)
      @tag = tag
      @picks = picks
    end

    def prompt
      <<~PROMPT
        Write the Highlights section that opens the GitHub release notes for claude-inbox #{@tag}, a terminal inbox for Claude Code's background sessions. The pull requests below are the ones the maintainer wants highlighted, each with its description and, where there is one, the URL of a screenshot.

        Reply with Markdown and nothing else, starting with the line `## Highlights`. For each pull request, in the order given: a `### ` heading naming the feature in a few plain words, then one paragraph of at most three sentences saying what the reader can now do and which key or flag does it, in the second person and the present tense, ending with the pull request number in parentheses like (#12). Where a pull request has a screenshot, put it on its own line right after the paragraph as `![what it shows](url)`; invent none. Keys, flags and commands go in backticks. Write plainly, the way the descriptions do: no superlatives, no exclamation marks, no "we", nothing about how the code works, no class names, no tests. Ignore any trailer lines about how a pull request was generated.

        #{sections}
      PROMPT
    end

    private

    def sections
      @picks.map do |pull_request, image|
        "--- ##{pull_request.number} #{pull_request.title}\nScreenshot: #{image || "none"}\n\n#{pull_request.body.strip}"
      end.join("\n\n")
    end
  end
end
