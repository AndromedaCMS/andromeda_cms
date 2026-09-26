# frozen_string_literal: true

require "andromeda_cms"

module Andromeda
  module Generators
    # `rails g andromeda:install` -- one-time setup for a host
    # application: the content directory, the component partials directory,
    # a commented initializer, and the two ignore files expect
    # `.andromeda/` (the conversion cache) and the copied-image build
    # directory to be excluded from.
    #
    # Every step here is safe to run twice: directories/files Thor already
    # knows about follow its normal conflict handling, and the ignore-file
    # lines are only appended when they are not already present.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      IGNORE_LINES = ["/.andromeda/", "/app/assets/builds/andromeda/"].freeze

      def create_content_directory
        empty_directory "app/content"
        create_file "app/content/.keep"
      end

      def create_components_directory
        path = Andromeda.config.components_path
        empty_directory path
        create_file "#{path}/.keep"
      end

      def create_initializer
        copy_file "initializer.rb", "config/initializers/andromeda.rb"
      end

      def update_ignore_files
        [".gitignore", ".dockerignore"].each { |filename| append_ignore_lines(filename) }
      end

      def show_next_steps
        say ""
        say "Andromeda is set up. Next steps:"
        say ""
        say "  1. Generate a collection:"
        say "       rails generate andromeda:collection posts title:string pub_date:date"
        say ""
        say "  2. Or import existing content from an Astro project:"
        say "       rails generate andromeda:import_astro path/to/astro-project"
        say ""
      end

      private

      # Appends whichever of IGNORE_LINES aren't already in `filename`, or
      # explains why nothing happened when the file doesn't exist -- an
      # app without Docker, for instance, has no .dockerignore and should
      # not get one invented for it.
      def append_ignore_lines(filename)
        path = File.join(destination_root, filename)

        unless File.exist?(path)
          say_status :skip, "#{filename} not found -- if you add one later, also add: #{IGNORE_LINES.join(", ")}", :yellow
          return
        end

        existing_lines = File.readlines(path, chomp: true)
        missing = IGNORE_LINES.reject { |line| existing_lines.include?(line) }
        if missing.empty?
          say_status :identical, filename, :blue
          return
        end

        append_to_file filename, "#{missing.join("\n")}\n"
      end
    end
  end
end
