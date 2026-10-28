# frozen_string_literal: true

module ClaudeInbox
  class App
    # Handing the terminal to a session and getting it back, and asking the
    # daemon to stop or delete one.
    module Attaching
      private

      def activate
        return set_expanded(true) if @selected&.fold?
        return @modal = Dialog::Confirm.new(:adopt, @selected.key) if selected_session&.remote? && selected_session.can?(:adopt)
        attach(selected_session) if require_actionable(:attach)
      end

      # Guard for attach/stop/delete: refuse politely on a terminal or remote
      # row, and say nothing for an action the row's harness has not got.
      def require_actionable(action)
        s = selected_session
        return s.can?(action) if s&.actionable?
        if s&.interactive?
          notice(s.remote? ? "that's a remote session — Enter adopts it, w opens it at claude.ai/code" : "that's your own terminal — switch to that window")
        end
        false
      end

      # The pane in the attached session may ask for a different one: the
      # attach ends and the next starts without passing through the list. The
      # poller keeps running meanwhile, so the pane's snapshot stays fresh. A
      # failed attach leaves its reason on screen until a key is pressed.
      def attach(session)
        while session
          @switch.clear
          from = session.session_id
          @store.visit(session.key) do
            @terminal.release do
              @terminal.pause unless @client.attach(session) { @switch.requested_for?(from) }
            end
          end
          @poller.soon
          session = session_for(@switch.take(@store.sessions.select(&:attachable?).map(&:key)))
        end
      end

      # A session just started or adopted, which no poll has listed yet.
      def started(id, harness: :claude, cwd: nil) = Session.new(harness: harness, id: id, cwd: cwd, kind: "background")

      def adopt_session(key)
        s = session_for(key)
        return unless s&.remote? && s.can?(:adopt)
        notice("adopting #{s.display_name}…")
        in_background do
          id = @client.adopt(session_id: s.session_id, cwd: s.cwd, pid: s.pid)
          @queue << [:notice, "adopted as #{id}"]
          @queue << [:select, id]
          @queue << [:attach, started(id)]
        end
      end

      def open_confirm(kind)
        return unless require_actionable(kind)
        @modal = Dialog::Confirm.new(kind, @selected.key, label_for(@selected.key), harness: selected_session.harness)
      end

      # A Codex thread between turns has nothing to stop, which is no failure.
      def stop_session(id)
        return unless (s = session_for(id))
        label = label_for(id)
        in_background do
          @queue << [:notice, "#{label} has no turn running"] unless @client.stop(s)
          @poller.soon
        end
      end

      def delete_session(id)
        return unless (s = session_for(id))
        label = label_for(id)
        notice("deleting #{label}…")
        in_background do
          @client.rm(s)
          @store.forget(id)
          @queue << [:notice, "deleted #{label}"]
          @poller.soon
        end
      end
    end
  end
end
