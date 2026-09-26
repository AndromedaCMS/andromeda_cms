# frozen_string_literal: true

require_relative "boot"

# Only the frameworks the gem actually integrates with are loaded: a smaller
# boot keeps the suite fast and proves the gem does not silently depend on
# Active Record or the rest of the stack.
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"

require "andromeda_cms"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "dummy"
    config.logger = Logger.new(IO::NULL)
    config.active_support.to_time_preserves_timezone = :zone
    # Rack::Test drives requests as example.org; host authorization has
    # nothing to protect in a test app.
    config.hosts.clear
  end
end
