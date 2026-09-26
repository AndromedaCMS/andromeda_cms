# frozen_string_literal: true

require "rails/railtie"
require_relative "helpers"

module Andromeda
  class Railtie < ::Rails::Railtie
    config.andromeda = Andromeda.config

    # Development converts on demand so edits show up without a build;
    # anywhere else the build is the only writer. Test behaves like
    # development so a suite never has to run the build task first.
    initializer "andromeda.mode" do
      Andromeda.config.mode = Rails.env.local? ? :development : :production
    end

    # A slug that matches no entry is a missing page, and should look like
    # one to browsers, crawlers and uptime monitors rather than a 500. Set at
    # class level, as Active Record does for RecordNotFound: ActionDispatch
    # copies this table while it initializes, before any initializer of ours.
    if config.respond_to?(:action_dispatch)
      config.action_dispatch.rescue_responses["Andromeda::EntryNotFound"] = :not_found
    end

    initializer "andromeda.helpers" do
      ActiveSupport.on_load(:action_view) { include Andromeda::Helpers }
    end

    # Entry classes are ordinary autoloaded constants, so Zeitwerk -- not
    # Kernel#load -- has to be the one that loads them; loading the files
    # directly would create a second copy of each class that Rails' reloader
    # neither tracks nor unloads. Eager-loading the directory on every
    # `to_prepare` also covers development, where nothing would otherwise
    # reference the classes until a request needs one.
    config.to_prepare do
      Andromeda::Registry.clear!
      directory = Rails.root.join(Andromeda.config.entry_class_path)
      next unless directory.directory?

      Rails.autoloaders.main.eager_load_dir(directory) if Rails.autoloaders.respond_to?(:main)
    end

    rake_tasks do
      load File.expand_path("tasks/andromeda.rake", __dir__)
    end
  end
end
