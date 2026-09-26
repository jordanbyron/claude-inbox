# frozen_string_literal: true

require_relative "agents_client"

module ClaudeInbox
  # The rules a new session's settings follow, whichever way it is asked
  # for: the `n` form, or a request that arrives as a hash of JSON values.
  module SessionRequest
    class Invalid < StandardError
      attr_reader :field

      def initialize(field, message)
        @field = field
        super(message)
      end
    end

    KEYS = %w[prompt name cwd model effort permission_mode worktree remote].freeze
    CHOICES = {
      model: AgentsClient::MODELS,
      effort: AgentsClient::EFFORTS,
      permission_mode: AgentsClient::PERMISSION_MODES
    }.freeze
    FLAGS = {true => true, false => false, "yes" => true, "no" => false}.freeze
    MAX_PROMPT = 100_000
    MAX_NAME = 100

    # The hash NewSessionForm#values builds, before `resolve`, from a
    # request's fields, or Invalid. "default" is nil. An unknown key is
    # refused rather than ignored, so a misspelt setting can't fall back to
    # its default unnoticed. A blank prompt, or a directory that does not
    # exist, passes here; `problem` reports it as the form does.
    def self.from_params(params, dirs: [])
      params = params.transform_keys(&:to_s)
      unknown = params.keys - KEYS
      raise Invalid.new(unknown.first.to_sym, "unknown key: #{unknown.first.inspect}") if unknown.any?
      {
        prompt: prompt_param(params["prompt"]),
        name: name_param(params["name"]),
        cwd: cwd_param(params["cwd"], dirs),
        model: choice_param(:model, params["model"]),
        effort: choice_param(:effort, params["effort"]),
        permission_mode: choice_param(:permission_mode, params["permission_mode"]),
        worktree: flag_param(:worktree, params["worktree"]) || false,
        remote: flag_param(:remote, params["remote"])
      }
    end

    # Unset Remote Control follows /config, then is passed either way so
    # the daemon records it in respawnFlags. The rest stay nil, for the CLI.
    def self.resolve(values, defaults)
      values[:remote].nil? ? values.merge(remote: defaults.remote == "yes") : values
    end

    # What stops these values from starting a session, as [field, message]
    # for the form to show and focus, or nil when nothing does.
    def self.problem(values)
      return [:prompt, "a prompt is required"] if values[:prompt].empty?
      return [:cwd, "no such directory: #{values[:cwd]}"] unless File.directory?(values[:cwd])
      nil
    end

    # Saved images go into the prompt as the @ mentions the CLI reads. An
    # `[Image #n]` becomes the nth path, the way a chip expands in the form;
    # a path the prompt never points at goes on the end.
    def self.attach(prompt, paths)
      used = []
      text = prompt.gsub(/\[Image #(\d+)\]/i) do |token|
        n = token[/\d+/].to_i
        next token unless n.between?(1, paths.size)
        used << n
        AgentsClient.mention(paths[n - 1])
      end
      rest = paths.reject.with_index(1) { |_, n| used.include?(n) }.map { |path| AgentsClient.mention(path) }
      [text, rest.join("\n")].reject(&:empty?).join("\n\n")
    end

    # A session's cwd may sit inside a worktree another agent is using;
    # carrying that into a new prompt would spawn the new agent there too,
    # writing over the same files. Fall back to the repo it was cut from.
    def self.strip_worktree(cwd) = cwd.to_s.sub(%r{/\.claude/worktrees/[^/]+(?:/.*)?\z}, "")

    # The daemon's summary line can echo the prompt to the terminal, so no
    # control character but tab and newline gets that far. A CRLF, the
    # newline an HTTP client may send, is taken as a newline.
    def self.prompt_param(value)
      prompt = string_param(:prompt, value || "").strip.gsub(/\r\n?/, "\n")
      raise Invalid.new(:prompt, "the prompt is over #{MAX_PROMPT} characters") if prompt.length > MAX_PROMPT
      if prompt.match?(/[[:cntrl:]&&[^\t\n]]/)
        raise Invalid.new(:prompt, "the prompt has a control character other than tab or newline")
      end
      prompt
    end

    # The name comes back as the row's label, printed as it is.
    def self.name_param(value)
      return nil if value.nil?
      name = string_param(:name, value).strip
      raise Invalid.new(:name, "a name is one line") if name.match?(/[[:cntrl:]\u2028\u2029]/)
      raise Invalid.new(:name, "the name is over #{MAX_NAME} characters") if name.length > MAX_NAME
      name.empty? ? nil : name
    end

    # The fewest trailing components that name `path` alone among `dirs`.
    def self.label(path, dirs)
      parts = path.split("/").reject(&:empty?)
      (1..parts.size).each do |n|
        label = parts.last(n).join("/")
        return label if dirs.one? { |other| other.end_with?("/#{label}") }
      end
      path
    end

    # A path is taken as given. Anything else names one of `dirs` by its
    # `label`.
    def self.cwd_param(value, dirs)
      cwd = string_param(:cwd, value || "").strip
      raise Invalid.new(:cwd, "a directory is required") if cwd.empty?
      raise Invalid.new(:cwd, "a directory is one line") if cwd.match?(/[[:cntrl:]\u2028\u2029]/)
      return File.expand_path(cwd) if cwd.match?(%r{\A(/|~(/|\z))})
      found = dirs.select { |dir| dir.end_with?("/#{cwd}") }
      raise Invalid.new(:cwd, "no directory called #{cwd}") if found.empty?
      raise Invalid.new(:cwd, "#{cwd} could be any of #{found.join(", ")}") if found.size > 1
      found.first
    end

    def self.choice_param(key, value)
      return nil if value.nil? || value == "default"
      return value if CHOICES[key].include?(value)
      raise Invalid.new(key, "#{key} is one of #{CHOICES[key].join(", ")}")
    end

    def self.flag_param(key, value)
      return nil if value.nil?
      FLAGS.fetch(value) { raise Invalid.new(key, "#{key} is true, false, yes or no") }
    end

    # Each of these ends up in an argv or a path, where a NUL byte raises.
    # The bytes are checked as UTF-8 whatever the string's tag says: a
    # binary string always passes `valid_encoding?`.
    def self.string_param(key, value)
      raise Invalid.new(key, "#{key} must be a string") unless value.is_a?(String)
      text = String.new(value, encoding: Encoding::UTF_8)
      raise Invalid.new(key, "#{key} is not valid UTF-8") unless text.valid_encoding?
      raise Invalid.new(key, "#{key} contains a NUL byte") if text.include?("\0")
      text
    end

    private_class_method :prompt_param, :name_param, :cwd_param, :choice_param, :flag_param, :string_param
  end
end
