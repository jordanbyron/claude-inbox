# frozen_string_literal: true

module ClaudeInbox
  class App
    # Handing the terminal to a session and getting it back, and asking the
    # daemon to stop or delete one.
    module Attaching
      private

      def activate
        return set_expanded(true) if @selected&.fold?
        return @modal = Dialog::Confirm.new(:adopt, @selected.key) if selected_session&.remote?
        attach(@selected.key) if require_actionable
      end

      # Guard for attach/stop: refuse politely on a terminal or remote row.
      def require_actionable
        s = selected_session
        return true if s&.actionable?
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
          @store.acknowledge(id)
          @switch.clear
          from = session_for(id)&.session_id
          @terminal.release do
            @terminal.pause unless @client.attach(id) { @switch.requested_for?(from) }
          end
          id = @switch.take(@store.actionable_keys)
        end
      end

      def adopt_session(key)
        s = session_for(key)
        return unless s&.remote?
        notice("adopting #{s.display_name}…")
        in_background do
          id = @client.adopt(session_id: s.session_id, cwd: s.cwd, pid: s.pid)
          @queue << [:notice, "adopted as #{id}"]
          @queue << [:select, id]
          @queue << [:attach, id]
        end
      end

      def open_confirm(kind)
        return unless require_actionable
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
