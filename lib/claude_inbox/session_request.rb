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

    # The hash NewSessionForm#values builds, from a request's fields, or
    # Invalid. An unknown key is refused rather than ignored, so a misspelt
    # setting can't fall back to its default unnoticed. A blank prompt or a
    # missing directory passes here; `problem` says so, as the form does.
    def self.from_params(params, dirs: [])
      params = params.transform_keys(&:to_s)
      unknown = params.keys - KEYS
      raise Invalid.new(unknown.first, "unknown key: #{unknown.first}") if unknown.any?
      {
        prompt: prompt_param(params["prompt"]),
        name: name_param(params["name"]),
        cwd: cwd_param(params["cwd"], dirs),
        model: choice_param(:model, params["model"]),
        effort: choice_param(:effort, params["effort"]),
        permission_mode: choice_param(:permission_mode, params["permission_mode"]),
        worktree: flag_param(:worktree, params["worktree"]),
        remote: flag_param(:remote, params["remote"])
      }
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

    def self.prompt_param(value)
      prompt = string_param(:prompt, value || "").strip
      raise Invalid.new(:prompt, "the prompt is over #{MAX_PROMPT} characters") if prompt.length > MAX_PROMPT
      prompt
    end

    def self.name_param(value)
      return nil if value.nil?
      name = string_param(:name, value).strip
      raise Invalid.new(:name, "a name is one line") if name.match?(/[\r\n]/)
      raise Invalid.new(:name, "the name is over #{MAX_NAME} characters") if name.length > MAX_NAME
      name.empty? ? nil : name
    end

    # A path is taken as given. Anything else names one of `dirs` by its
    # last components, the label a remote client picks it by.
    def self.cwd_param(value, dirs)
      cwd = string_param(:cwd, value || "").strip
      raise Invalid.new(:cwd, "a directory is required") if cwd.empty?
      return File.expand_path(cwd) if cwd.match?(%r{\A(/|~(/|\z))})
      found = dirs.select { |dir| dir.end_with?("/#{cwd}") }
      raise Invalid.new(:cwd, "no directory called #{cwd}") if found.empty?
      raise Invalid.new(:cwd, "#{cwd} could be any of #{found.join(", ")}") if found.size > 1
      found.first
    end

    def self.choice_param(key, value)
      value = "default" if value.nil?
      return value if CHOICES[key].include?(value)
      raise Invalid.new(key, "#{key} is one of #{CHOICES[key].join(", ")}")
    end

    def self.flag_param(key, value)
      return false if value.nil?
      FLAGS.fetch(value) { raise Invalid.new(key, "#{key} is true, false, yes or no") }
    end

    # Each of these ends up in an argv or a path, where a NUL byte raises.
    def self.string_param(key, value)
      raise Invalid.new(key, "#{key} must be a string") unless value.is_a?(String)
      raise Invalid.new(key, "#{key} is not valid UTF-8") unless value.valid_encoding?
      raise Invalid.new(key, "#{key} contains a NUL byte") if value.include?("\0")
      value
    end

    private_class_method :prompt_param, :name_param, :cwd_param, :choice_param, :flag_param, :string_param
  end
end
