# frozen_string_literal: true

# The pairing dialog's current frame as one string, for the PairingDialog
# specs. Relies on the group's let value dialog.
module PairingDialogHelpers
  def box(width = 120) = dialog.frame(width).join("\n")
end

RSpec.configure { |config| config.include PairingDialogHelpers, :pairing_dialog }
