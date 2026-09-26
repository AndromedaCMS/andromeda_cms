# frozen_string_literal: true

require "andromeda_cms"
require "active_support/core_ext/string/inflections"

module Andromeda
  module Generators
    # `rails g andromeda:collection NAME [field:type ...]` --
    # everything a new collection needs: the entry class, a
    # plain Rails controller/views, a route, and a starter content file.
    #
    # `NAME` names the collection exactly as it will appear under
    # `app/content/` and is used as-is for the controller/views/route/
    # content directory (the controller follows the URL, not the
    # content namespace). Only the entry *class* is singularized, matching
    # `app/models/content/post.rb` for a `posts` collection.
    #
    # All file content is built directly (rather than via `.tt` ERB
    # templates) since every piece of it -- the namespace nesting, the
    # attribute list, which attribute doubles as a title -- depends on
    # generator input in a way a static template can't express cleanly.
    class CollectionGenerator < Rails::Generators::NamedBase
      # Deliberately named `fields`, not `attributes`: Rails::Generators::
      # NamedBase auto-detects an `attributes` argument (`respond_to?
      # (:attributes)`) and rewrites it into GeneratedAttribute objects
      # using its own `field:type:index` syntax (`index` meaning a DB
      # index), which collides with our `field:type:collection` syntax for
      # :reference attributes.
      argument :fields, type: :array, default: [], banner: "field:type field:type"

      # Schema types (schema.rb's TYPES) that make sense to request from the
      # command line; anything else -- or no `:type` at all -- defaults to
      # :string, the same fallback Rails' own generators use.
      TYPE_ALIASES = {
        "string" => :string,
        "date" => :date,
        "datetime" => :datetime,
        "boolean" => :boolean,
        "bool" => :boolean,
        "integer" => :integer,
        "int" => :integer,
        "array" => :array,
        "image" => :image,
        "reference" => :reference
      }.freeze

      def create_model
        create_file model_path, model_content
      end

      def create_controller
        create_file "app/controllers/#{collection_name}_controller.rb", controller_content
      end

      def create_views
        create_file "app/views/#{collection_name}/index.html.erb", index_view_content
        create_file "app/views/#{collection_name}/show.html.erb", show_view_content
      end

      # Only appends the route when it is not already there, so running the
      # generator twice (e.g. after adding a field) never duplicates it --
      # Thor's own `route` action always appends unconditionally.
      def add_route
        routes_path = File.join(destination_root, "config/routes.rb")

        if File.exist?(routes_path) && File.read(routes_path).include?(route_line)
          say_status :identical, "config/routes.rb (route already present)", :blue
        else
          route route_line
        end
      end

      def create_starter_content
        parsed_attributes.each do |attr|
          next unless attr[:type] == :image

          # A schema :image attribute is validated by checking the file
          # actually exists (Schema#coerce_image) -- an empty placeholder
          # satisfies that check without requiring a real asset.
          create_file "app/content/#{collection_name}/#{attr[:name]}#{IMAGE_EXTENSION}", ""
        end
        create_file "app/content/#{collection_name}/hello-world.md", starter_content
      end

      private

      IMAGE_EXTENSION = ".png"

      # The collection name exactly as given, underscored -- this is what
      # the route, controller, views and content directory all use.
      def collection_name
        @collection_name ||= name.underscore
      end

      def singular_name
        @singular_name ||= collection_name.singularize
      end

      def namespace_modules
        @namespace_modules ||= Andromeda.config.entry_namespace.split("::")
      end

      def class_basename
        singular_name.camelize
      end

      def full_class_name
        (namespace_modules + [class_basename]).join("::")
      end

      def route_line
        "resources :#{collection_name}, only: %i[index show], param: :slug"
      end

      def parsed_attributes
        @parsed_attributes ||= fields.map { |raw| parse_attribute(raw) }
      end

      def parse_attribute(raw)
        field, type_str, extra = raw.split(":", 3)
        type = TYPE_ALIASES.fetch(type_str.to_s, :string)
        { name: field.underscore, type: type, extra: extra }
      end

      def attribute_declaration(attr)
        case attr[:type]
        when :boolean
          "attribute :#{attr[:name]}, :boolean, default: false"
        when :array
          "attribute :#{attr[:name]}, :array, of: :string, default: []"
        when :reference
          target = (attr[:extra] || attr[:name].pluralize).to_sym
          "attribute :#{attr[:name]}, :reference, collection: :#{target}"
        else
          "attribute :#{attr[:name]}, :#{attr[:type]}"
        end
      end

      def model_path
        File.join(Andromeda.config.entry_class_path, "#{singular_name}.rb")
      end

      def model_content
        indent = "  " * namespace_modules.size
        lines = ["# frozen_string_literal: true", ""]
        namespace_modules.each_with_index { |mod, i| lines << "#{"  " * i}module #{mod}" }
        lines << "#{indent}class #{class_basename} < Andromeda::Entry"
        lines << "#{indent}  collection :#{collection_name}, base: \"app/content/#{collection_name}\", " \
                 "pattern: \"**/*.{md,mdx}\""
        unless parsed_attributes.empty?
          lines << ""
          parsed_attributes.each { |attr| lines << "#{indent}  #{attribute_declaration(attr)}" }
        end
        lines << ""
        lines << "#{indent}  # scope :published, -> { where(draft: false) }"
        lines << "#{indent}end"
        namespace_modules.size.downto(1) { |i| lines << "#{"  " * (i - 1)}end" }
        "#{lines.join("\n")}\n"
      end

      def controller_content
        order_attribute = parsed_attributes.find { |attr| %i[date datetime].include?(attr[:type]) }
        listing = if order_attribute
                    "#{full_class_name}.all.order(#{order_attribute[:name]}: :desc)"
                  else
                    "#{full_class_name}.all"
                  end

        <<~RUBY
          # frozen_string_literal: true

          class #{collection_name.camelize}Controller < ApplicationController
            def index
              @entries = #{listing}
            end

            def show
              @entry = #{full_class_name}.find(params[:slug])
            end
          end
        RUBY
      end

      # Best-effort attribute to display as an entry's title: the first
      # declared :string attribute, or `id` when none was declared.
      def title_method
        title_attribute = parsed_attributes.find { |attr| attr[:type] == :string }
        title_attribute ? title_attribute[:name] : "id"
      end

      def index_view_content
        <<~ERB
          <h1><%= "#{collection_name.humanize}" %></h1>
          <ul>
            <% @entries.each do |entry| %>
              <li><%= link_to entry.#{title_method}, #{collection_name}_path(entry.id) %></li>
            <% end %>
          </ul>
        ERB
      end

      def show_view_content
        <<~ERB
          <article>
            <h1><%= @entry.#{title_method} %></h1>
            <%= andromeda_content @entry %>
          </article>
        ERB
      end

      def starter_content
        frontmatter_lines = parsed_attributes.filter_map { |attr| starter_frontmatter_line(attr) }

        <<~MARKDOWN
          ---
          #{frontmatter_lines.join("\n")}
          ---

          ## Getting started

          Edit this file, or delete it and add your own content.
        MARKDOWN
      end

      def starter_frontmatter_line(attr)
        case attr[:type]
        when :string then "#{attr[:name]}: Hello World"
        when :date then "#{attr[:name]}: #{Date.today.iso8601}"
        when :datetime then "#{attr[:name]}: #{Time.now.utc.iso8601}"
        when :boolean then "#{attr[:name]}: false"
        when :integer then "#{attr[:name]}: 1"
        when :array then "#{attr[:name]}: [example]"
        when :image then "#{attr[:name]}: #{attr[:name]}#{IMAGE_EXTENSION}"
        when :reference then "#{attr[:name]}: example"
        end
      end
    end
  end
end
