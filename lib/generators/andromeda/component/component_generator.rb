# frozen_string_literal: true

require "andromeda_cms"
require "active_support/core_ext/string/inflections"

module Andromeda
  module Generators
    # `rails g andromeda:component NAME [prop ...]` -- a starter
    # partial for an MDX component, named by convention
    # (`Callout` -> `_callout.html.erb`) so no registration step is
    # needed for the common case.
    class ComponentGenerator < Rails::Generators::NamedBase
      argument :props, type: :array, default: [], banner: "prop prop"

      # An MDX tag is a single JSX identifier (`<Callout>`), never a
      # namespaced or dotted one -- reject anything NamedBase's own parsing
      # would otherwise silently accept (e.g. it treats `foo/bar` as a
      # namespace and `foo.bar` as one odd file name).
      VALID_NAME_RE = /\A[A-Za-z][A-Za-z0-9_]*\z/

      def validate_component_name!
        return if name.match?(VALID_NAME_RE)

        raise ArgumentError,
              "invalid component name #{name.inspect} -- use a single CamelCase or underscored word " \
              "(e.g. `Callout` or `callout`); it becomes " \
              "#{Andromeda.config.components_path}/_#{name.underscore}.html.erb"
      end

      def create_partial
        create_file "#{Andromeda.config.components_path}/_#{underscored_name}.html.erb", partial_content
      end

      private

      def underscored_name
        name.underscore
      end

      def tag_name
        name.camelize
      end

      def partial_content
        <<~ERB
          #{usage_comment}
          <div class="#{underscored_name.dasherize}">
          #{prop_lines.join("\n")}#{"\n" unless prop_lines.empty?}  <%= content %>
          </div>
        ERB
      end

      def prop_lines
        props.map do |prop|
          local = prop.underscore
          "  <% if local_assigns[:#{local}] %><p class=\"#{underscored_name.dasherize}__#{local.dasherize}\">" \
            "<%= #{local} %></p><% end %>"
        end
      end

      def usage_comment
        attrs = props.map { |prop| "#{prop.underscore.camelize(:lower)}=\"...\"" }.join(" ")
        opening = attrs.empty? ? "<#{tag_name}>" : "<#{tag_name} #{attrs}>"

        <<~ERB.chomp
          <%# MDX usage:
                #{opening}
                  Body text.
                </#{tag_name}>
          %>
        ERB
      end
    end
  end
end
