# frozen_string_literal: true

module ClaudeInbox
  class App
    # Starting a session: the `n` form, the spawn off the main thread, the
    # two ways it comes back, and a start that arrived from another device.
    # Owns the trusted directories and the colour the form is drawn in.
    module Spawning
      private

      def open_new_session
        cwd = selected_session&.cwd || Dir.pwd
        dirs = SessionRequest.directories(@store.sessions, @trust.call)
        @modal = NewSessionForm.new(cwd: SessionRequest.strip_worktree(cwd), color: @color, dirs: dirs)
      end

      # `:start`/`:start_and_attach` leave the form as `@modal`, now busy: it
      # closes itself once the spawn is confirmed to have started (`:form_started`)
      # or reopens with the failure and the prompt intact (`:form_failed`).
      def handle_form_key(name, key)
        form = @modal
        case form.press(name, key)
        when :cancel then @modal = nil
        when :start then start_session(form, attach: false)
        when :start_and_attach then start_session(form, attach: true)
        end
      end

      # `attach:` hands the terminal over as soon as the session starts. Without
      # it we stay in the inbox and poll, so the new row shows up right away
      # rather than at the next tick.
      def start_session(form, attach:)
        v = form.values
        notice("starting session…")
        in_background do
          id = @client.spawn(**v)
          @queue << [:notice, "started #{id}"]
          @queue << [:form_started, form]
          @queue << [:select, id]
          attach ? @queue << [:attach, id] : @poller.soon
        rescue AgentsClient::Error => e
          @queue << [:form_failed, form, e.message]
        end
      end

      def form_started(form)
        @modal = nil if @modal.equal?(form)
      end

      # A spawn failure hands the form back rather than just logging it, so
      # the composed prompt survives (see NewSessionForm#submission_failed).
      def form_failed(form, message)
        @modal.equal?(form) ? form.submission_failed(message) : (@error = message)
      end

      # Someone at the desk may be mid-thought, so a start from another
      # device never moves the cursor, attaches or closes what is open.
      def remote_started(id, via)
        notice("started #{id} from #{via}")
        @poller.soon
      end
    end
  end
end
