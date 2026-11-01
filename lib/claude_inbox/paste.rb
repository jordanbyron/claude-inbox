# frozen_string_literal: true

module ClaudeInbox
  # Splits bracketed pastes (what the terminal sends once App turns on
  # \e[?2004h) out of the raw keypress stream. A paste can straddle several
  # non-blocking reads, so an open one waits here for its closing bracket.
  #
  #   p = Paste.new
  #   p.feed("j\e[200~hel")     # => [[:key, "j"]]
  #   p.feed("lo\e[201~k")      # => [[:paste, "hello"], [:key, "k"]]
  class Paste
    OPEN = "\e[200~"
    CLOSE = "\e[201~"

    def initialize
      @open = nil
    end

    def pasting? = !@open.nil?

    def feed(raw)
      out = []
      rest = raw
      until rest.empty?
        if @open
          body, close, rest = rest.partition(CLOSE)
          @open << body
          break if close.empty?
          out << [:paste, @open]
          @open = nil
        else
          keys, open, rest = rest.partition(OPEN)
          out << [:key, keys] unless keys.empty?
          @open = +"" unless open.empty?
        end
      end
      out
    end
  end
end
