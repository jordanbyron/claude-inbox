# frozen_string_literal: true

require "date"

module ClaudeInbox
  # The wake time a typed snooze means, as an epoch, or nil for text it does
  # not read. Takes a duration (`45m`, `2h`, `3d`), a clock time (`17:00`,
  # `5pm`) for the next such time, a weekday (`fri`, `friday`) for that day
  # at 9am, `tomorrow`, or `tonight`/`evening` for the next 6pm. A weekday
  # or `tomorrow` may carry a time after it (`fri 5pm`).
  module SnoozeTime
    UNITS = {"m" => 60, "min" => 60, "mins" => 60, "minute" => 60, "minutes" => 60,
             "h" => 3600, "hr" => 3600, "hrs" => 3600, "hour" => 3600, "hours" => 3600,
             "d" => 86_400, "day" => 86_400, "days" => 86_400}.freeze
    WEEKDAYS = {"sun" => 0, "mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6}.freeze
    DURATION = /\A(\d+)\s*(#{UNITS.keys.join("|")})\z/
    WEEKDAY = /\A(#{WEEKDAYS.keys.join("|")})[a-z]*\z/
    CLOCK = /\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/
    MORNING = [9, 0].freeze
    EVENING = [18, 0].freeze

    def self.parse(text, now)
      text = text.to_s.strip.downcase
      if (m = DURATION.match(text))
        return m[1].to_i.positive? ? now.to_i + m[1].to_i * UNITS[m[2]] : nil
      end
      head, rest = text.split(/\s+/, 2)
      case head
      when nil then nil
      when "tonight", "evening" then rest.nil? ? next_at(now, EVENING) : nil
      when "tomorrow" then (hm = time_of_day(rest)) && at(now, 1, hm)
      when WEEKDAY then (hm = time_of_day(rest)) && weekday(now, WEEKDAYS[head[0, 3]], hm)
      else (hm = clock(text)) && next_at(now, hm)
      end
    end

    # [hour, minute] for `17:00`, `5pm` or `5:30pm`; a bare number is not a time.
    def self.clock(text)
      m = CLOCK.match(text)
      return nil if m.nil? || (m[2].nil? && m[3].nil?)
      hour, minute = m[1].to_i, m[2].to_i
      return nil if minute > 59
      if m[3]
        return nil unless (1..12).cover?(hour)
        hour = hour % 12 + ((m[3] == "pm") ? 12 : 0)
      elsif hour > 23
        return nil
      end
      [hour, minute]
    end

    # A day's snooze: the time after the word, else 9am.
    def self.time_of_day(rest) = rest ? clock(rest) : MORNING

    # That day at `hm`, or a week on when it has already passed.
    def self.weekday(now, wday, hm)
      t = at(now, (wday - now.wday) % 7, hm)
      (t > now.to_i) ? t : t + 7 * 86_400
    end

    # Today at `hm`, or tomorrow when it has already passed.
    def self.next_at(now, hm)
      t = at(now, 0, hm)
      (t > now.to_i) ? t : at(now, 1, hm)
    end

    def self.at(now, days, (hour, minute))
      day = now.to_date + days
      Time.new(day.year, day.month, day.day, hour, minute, 0, now.utc_offset).to_i
    end
    private_class_method :clock, :time_of_day, :weekday, :next_at, :at
  end
end
