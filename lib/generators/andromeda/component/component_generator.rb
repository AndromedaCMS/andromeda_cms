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

      # A prop becomes a Ruby local (`<%= title %>`, `locals: (title: nil)`),
      # so it must be a plain identifier that is not a keyword. Props come
      # from MDX attributes (`a:b`, `$x`, `class`), which are legal JSX but
      # would produce a template that fails to compile.
      LOCAL_NAME_RE = /\A[a-z_][a-zA-Z0-9_]*\z/
      RESERVED_WORDS = %w[
        __ENCODING__ __LINE__ __FILE__ BEGIN END alias and begin break case class def defined? do else elsif
        end ensure false for if in module next nil not or redo rescue retry return self super then true undef
        unless until when while yield
      ].freeze

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

      # `content` is always declared for the tag's body (see
      # `strict_locals`), so a prop of that name would be declared twice.
      def valid_local?(prop)
        local = prop.underscore
        local.match?(LOCAL_NAME_RE) && !RESERVED_WORDS.include?(local) && local != "content"
      end

      def valid_props
        props.select { |prop| valid_local?(prop) }
      end

      # Rejected props are not emitted as code; a comment tells the author
      # to rename them by hand. The prop text is attacker-influenced (it
      # comes from MDX), so it must not be able to close the ERB tag or
      # start a new line.
      def rejected_prop_lines
        props.reject { |prop| valid_local?(prop) }.map do |prop|
          safe = prop.gsub(/\s+/, " ").gsub("%>", "")
          "<%# TODO: prop `#{safe}` is not a valid local name -- rename it by hand. %>"
        end
      end

      def partial_content
        <<~ERB
          #{usage_comment}
          #{([strict_locals] + rejected_prop_lines).join("\n")}
          <div class="#{underscored_name.dasherize}">
          #{prop_lines.join("\n")}#{"\n" unless prop_lines.empty?}  <%= content %>
          </div>
        ERB
      end

      # Every prop is optional, and `content` is declared too: it is passed
      # even to a self-closing tag (`<Callout />`), where it is empty.
      def strict_locals
        locals = valid_props.map { |prop| "#{prop.underscore}: nil" } << "content: nil"
        "<%# locals: (#{locals.join(', ')}) %>"
      end

      def prop_lines
        valid_props.map do |prop|
          local = prop.underscore
          "  <% if local_assigns[:#{local}] %><p class=\"#{underscored_name.dasherize}__#{local.dasherize}\">" \
            "<%= #{local} %></p><% end %>"
        end
      end

      def usage_comment
        attrs = valid_props.map { |prop| "#{prop.underscore.camelize(:lower)}=\"...\"" }.join(" ")
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
