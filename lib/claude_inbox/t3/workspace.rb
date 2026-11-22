# frozen_string_literal: true

require_relative "../subprocess"
require_relative "server"

module ClaudeInbox
  module T3
    # Where in T3 a new thread for a directory goes: the project and the
    # checkout `orchestration.launchThread` asks for. A directory in no
    # project becomes one, as T3 has no thread without one.
    class Workspace
      def initialize(server, cwd)
        @server = server
        @cwd = real(cwd)
      end

      def launch
        project = containing || same_repo || added
        root = real(project["workspaceRoot"])
        checkout = top && real(top)
        strategy = (checkout && checkout != root) ? {type: "existing_worktree", worktreePath: checkout} : {type: "root"}
        {projectId: project["id"], workspaceStrategy: strategy}
      end

      private

      def projects = @projects ||= @server.shell!["projects"] || []

      def containing = projects.select { |p| inside?(@cwd, real(p["workspaceRoot"])) }.max_by { |p| p["workspaceRoot"].size }

      # A worktree outside the project's folder, such as one T3 cut under ~/.t3/worktrees.
      def same_repo
        origin = git("remote", "get-url", "origin") or return
        projects.find { |p| p.dig("repositoryIdentity", "locator", "remoteUrl") == origin }
      end

      def added
        r = Subprocess.capture(@server.bin, "project", "add", "--base-dir", @server.home, top || @cwd)
        raise Server::Error, "t3 project add failed: #{r.err.strip}" unless r.success?
        @projects = nil
        containing or raise Server::Error, "T3 Code did not add #{@cwd} as a project"
      end

      def top = defined?(@top) ? @top : (@top = git("rev-parse", "--show-toplevel"))

      def git(*args)
        r = Subprocess.capture("git", "-C", @cwd, *args)
        r.out.strip if r.success? && !r.out.strip.empty?
      end

      def inside?(path, root) = path == root || path.start_with?(File.join(root, ""))

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end
    end
  end
end
