# frozen_string_literal: true

# StimulusReflex + CableReady configuration.
# Caching must be enabled for ActionCable to carry the session, but in a
# throwaway dev environment we relax the sanity check so the app boots
# without `rails dev:cache`.
StimulusReflex.configure do |config|
  config.on_failed_sanity_checks = :warn
end