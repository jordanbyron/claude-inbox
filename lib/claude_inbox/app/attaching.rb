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
        attach(@selected.key) if require_actionable(:attach)
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
      def attach(id)
        while id
          @switch.clear
          from = session_for(id)&.session_id
          @store.visit(id) do
            @terminal.release do
              @terminal.pause unless @client.attach(id) { @switch.requested_for?(from) }
            end
          end
          @poller.soon
          id = @switch.take(@store.sessions.select { |s| s.actionable? && s.can?(:attach) }.map(&:key))
        end
      end

      def adopt_session(key)
        s = session_for(key)
        return unless s&.remote? && s.can?(:adopt)
        notice("adopting #{s.display_name}…")
        in_background do
          id = @client.adopt(session_id: s.session_id, cwd: s.cwd, pid: s.pid)
          @queue << [:notice, "adopted as #{id}"]
          @queue << [:select, id]
          @queue << [:attach, id]
        end
      end

      def open_confirm(kind)
        return unless require_actionable(kind)
        @modal = Dialog::Confirm.new(kind, @selected.key, label_for(@selected.key))
      end

      def stop_session(id)
        in_background do
          @client.stop(id)
          @poller.soon
        end
      end

      def delete_session(id)
        label = label_for(id)
        notice("deleting #{label}…")
        in_background do
          @client.rm(id)
          @store.forget(id)
          @queue << [:notice, "deleted #{label}"]
          @poller.soon
        end
      end
    end
  end
end
