# frozen_string_literal: true

require "date"
require "time"

module Andromeda
  # A resolved `image()` attribute. Only holds enough
  # to prove the file exists and to locate it again -- no `url` yet, since
  # turning a content-relative path into a served asset URL is Propshaft's
  # job, not the schema's.
  # `asset` is filled in by the conversion pipeline once the file has been
  # copied into the asset pipeline; validation itself only proves the file
  # exists and stays inside the content root.
  Image = Struct.new(:path, :relative_path, :asset, keyword_init: true) do
    def to_s = relative_path
  end

  # A resolved `reference()` attribute, normalized to `{collection,
  # id}` exactly like Astro. Resolving `id` into the actual target entry
  # needs the collection registry, which does not exist at schema-validation
  # time -- this is deliberately just a pointer.
  Reference = Struct.new(:collection, :id, keyword_init: true)

  # A declarative set of attribute definitions for one entry type (a
  # Rails-style DSL, not Zod-style). `Schema` itself is loader/class-agnostic
  # -- it validates a Hash and returns a Hash -- so the class-level
  # `attribute` macro that `Andromeda::Entry` offers can be a
  # thin wrapper that builds and delegates to one of these instead of
  # duplicating any of this logic.
  #
  #   schema = Andromeda::Schema.new do |s|
  #     s.attribute :title,    :string,  required: true
  #     s.attribute :pub_date, :date,    required: true
  #     s.attribute :draft,    :boolean, default: false
  #     s.attribute :tags,     :array,   of: :string, default: []
  #   end
  #
  #   result = schema.validate({ "title" => "Hello", "pub_date" => "Jul 08 2022" })
  #   result.valid?      # => true
  #   result.data        # => { title: "Hello", pub_date: #<Date: 2022-07-08>, draft: false, tags: [] }
  #
  #   schema.validate!(data, path: "app/content/blog/x.md") # raises Andromeda::ValidationError on failure
  class Schema
    TYPES = %i[string integer float boolean date datetime array hash enum image reference].freeze

    # One declared attribute. Plain data, no behavior beyond `default_value`
    # -- everything else lives in Schema so a synthetic Attribute (built for
    # `of:` element coercion, see `#coerce_array`) works the same way a
    # top-level one does.
    Attribute = Struct.new(:name, :type, :required, :default, :of, :values, :collection, keyword_init: true) do
      # Called once per missing, non-required attribute. Arrays/Hashes are
      # duped so every entry lacking the attribute gets its own object --
      # otherwise all of them would share (and could mutate) the same
      # literal from the `attribute` call.
      def default_value
        return default.call if default.respond_to?(:call)
        return default.dup if default.is_a?(Array) || default.is_a?(Hash) || default.is_a?(String)

        default
      end
    end

    # One validation failure. `attribute` is nil for problems that are
    # about a raw key rather than a declared attribute (currently only
    # non-snake_case keys).
    Problem = Struct.new(:attribute, :message, keyword_init: true) do
      def to_s = message
    end

    # The outcome of `Schema#validate`. `data` is only populated when
    # `valid?` -- a partially-coerced Hash after some attributes failed
    # would invite callers to use data that was never actually validated.
    #
    # `data` mixes Symbol keys (declared attributes, coerced, defaults
    # applied) with String keys (unknown frontmatter, passed through
    # untouched) in the *same* Hash. That is a deliberate choice: code that
    # knows the schema reads `data[:title]` and gets a real Date/Boolean/etc,
    # while code that doesn't (a generic dumper, `andromeda:check`) can still
    # see whatever else was in the file under the key it was written with,
    # rather than that data silently vanishing. `unknown_keys` is the same
    # String-keyed subset on its own, for callers that only care about that.
    Result = Struct.new(:data, :problems, :unknown_keys, keyword_init: true) do
      def valid? = problems.empty?
    end

    def initialize
      @attributes = {}
      yield self if block_given?
    end

    attr_reader :attributes

    # @param name [Symbol, String]
    # @param type [Symbol] one of TYPES
    # @param required [Boolean] absent or explicit-nil fails validation;
    #   an explicit `false` (booleans!) or `0` does not.
    # @param default [Object, #call] used only when the key is absent from
    #   the data entirely -- see `#validate` for why an explicit nil does
    #   not also fall back to this.
    # @param of [Symbol] element type, :array only.
    # @param values [Array] allowed values, :enum only.
    # @param collection [Symbol, String] target collection name, :reference only.
    def attribute(name, type, required: false, default: nil, of: nil, values: nil, collection: nil)
      name = name.to_sym

      unless TYPES.include?(type)
        raise ArgumentError, "#{name}: unknown attribute type #{type.inspect} (expected one of #{TYPES.join(", ")})"
      end
      raise ArgumentError, "#{name}: :enum requires values:" if type == :enum && (values.nil? || values.empty?)
      raise ArgumentError, "#{name}: :reference requires collection:" if type == :reference && collection.nil?
      if type == :array && of && !TYPES.include?(of)
        raise ArgumentError, "#{name}: unknown element type #{of.inspect} for of:"
      end

      @attributes[name] = Attribute.new(
        name: name, type: type, required: required, default: default,
        of: of, values: values, collection: collection && collection.to_sym
      )
      self
    end

    # Validates `data` (String-keyed, as `Andromeda::Frontmatter.parse`
    # returns it) against every declared attribute and returns **all**
    # problems at once, Zod-style, rather than stopping at the first.
    #
    # @param data [Hash] frontmatter data with String keys.
    # @param path [String, nil] source file, attributed on problems/errors.
    # @param entry_path [String, nil] the entry file itself -- required to
    #   resolve :image attributes (relative to its directory).
    # @param content_root [String, nil] the collection's base directory --
    #   required to reject :image paths that escape it.
    # @return [Andromeda::Schema::Result]
    def validate(data, path: nil, entry_path: nil, content_root: nil)
      problems = []

      Andromeda::Frontmatter.non_snake_case_keys(data).each do |key|
        problems << Problem.new(attribute: nil, message: non_snake_case_message(key))
      end

      declared = {}
      attributes.each_value do |attr|
        key = attr.name.to_s

        unless data.key?(key)
          if attr.required
            problems << Problem.new(attribute: attr.name, message: "#{attr.name} is required")
          else
            declared[attr.name] = attr.default_value
          end
          next
        end

        value = data[key]

        if value.nil?
          # A key that is present but explicitly blank (`title:` with
          # nothing after it) means the author wrote *something* -- even if
          # that something is "nothing in particular" -- so it is kept as
          # nil rather than silently replaced by `default:`. Only a
          # required attribute rejects it.
          if attr.required
            problems << Problem.new(attribute: attr.name, message: "#{attr.name} is required")
          else
            declared[attr.name] = nil
          end
          next
        end

        coerced, error = coerce(attr, value, entry_path: entry_path, content_root: content_root)
        if error
          problems << Problem.new(attribute: attr.name, message: "#{attr.name}: #{error}")
        else
          declared[attr.name] = coerced
        end
      end

      known = attributes.keys.map(&:to_s)
      unknown = data.each_with_object({}) do |(key, value), out|
        out[key] = value if key.is_a?(String) && !known.include?(key)
      end

      Result.new(
        data: problems.empty? ? declared.merge(unknown) : nil,
        problems: problems,
        unknown_keys: unknown
      )
    end

    # @raise [Andromeda::ValidationError] listing every problem, unless valid.
    # @return [Hash] `result.data` -- see Result for its Symbol/String key mix.
    def validate!(data, path: nil, entry_path: nil, content_root: nil)
      result = validate(data, path: path, entry_path: entry_path, content_root: content_root)
      raise Andromeda::ValidationError.new(result.problems, path: path) unless result.valid?

      result.data
    end

    private

    def non_snake_case_message(key)
      fixed = key.gsub(/([a-z0-9])([A-Z])/, '\1_\2').tr("-", "_").downcase
      "#{key} is not snake_case (expected #{fixed}); run andromeda:fix to rename it"
    end

    # Returns `[coerced_value, nil]` on success or `[nil, error_message]`
    # otherwise. Kept as one dispatcher (rather than a Hash of coercers) so
    # `#coerce_array` can recurse into it for `of:` without building a
    # second Attribute-shaped indirection layer.
    def coerce(attr, value, entry_path:, content_root:)
      case attr.type
      when :string then coerce_string(value)
      when :integer then coerce_integer(value)
      when :float then coerce_float(value)
      when :boolean then coerce_boolean(value)
      when :date then coerce_date(value)
      when :datetime then coerce_datetime(value)
      when :array then coerce_array(attr, value, entry_path: entry_path, content_root: content_root)
      when :hash then coerce_hash(value)
      when :enum then coerce_enum(attr, value)
      when :image then coerce_image(value, entry_path: entry_path, content_root: content_root)
      when :reference then coerce_reference(attr, value)
      end
    end

    # Astro's base Zod types (z.string(), z.number(), z.boolean()) do not
    # coerce -- only `z.coerce.date()` does -- so a String stays
    # a type error here instead of silently becoming a number or vice versa.
    def coerce_string(value)
      return [value, nil] if value.is_a?(String)

      [nil, "#{value.inspect} is not a string"]
    end

    def coerce_integer(value)
      return [value, nil] if value.is_a?(Integer)
      # JavaScript has one number type, so Zod's `.int()` accepts `3.0`;
      # YAML hands Ruby a Float for it.
      return [value.to_i, nil] if value.is_a?(Float) && value.finite? && value == value.floor

      [nil, "#{value.inspect} is not an integer"]
    end

    def coerce_float(value)
      return [value.to_f, nil] if value.is_a?(Numeric)

      [nil, "#{value.inspect} is not a number"]
    end

    def coerce_boolean(value)
      return [value, nil] if value == true || value == false

      [nil, "#{value.inspect} is not a boolean"]
    end

    # `z.coerce.date()` accepts anything `new Date()` accepts, which
    # includes both `'Jul 08 2022'` and ISO strings -- Ruby's Date.parse
    # covers the same ground. YAML/TOML already hand back a real Date for
    # unquoted values (Andromeda::Frontmatter), so those pass through
    # untouched; only a String needs parsing.
    def coerce_date(value)
      case value
      when Date then [value.is_a?(DateTime) ? value.to_date : value, nil]
      when Time then [value.to_date, nil]
      when String
        begin
          [Date.parse(value), nil]
        rescue ArgumentError, TypeError
          [nil, "#{value.inspect} is not a valid date"]
        end
      else
        [nil, "#{value.inspect} is not a valid date"]
      end
    end

    def coerce_datetime(value)
      case value
      when Time then [value, nil]
      when Date then [value.to_time, nil]
      when String
        begin
          [Time.parse(value), nil]
        rescue ArgumentError, TypeError
          [nil, "#{value.inspect} is not a valid datetime"]
        end
      else
        [nil, "#{value.inspect} is not a valid datetime"]
      end
    end

    def coerce_array(attr, value, entry_path:, content_root:)
      return [nil, "#{value.inspect} is not an array"] unless value.is_a?(Array)
      return [value, nil] unless attr.of

      element_attr = Attribute.new(name: attr.name, type: attr.of)
      errors = []
      elements = value.each_with_index.map do |element, index|
        coerced, error = coerce(element_attr, element, entry_path: entry_path, content_root: content_root)
        errors << "[#{index}] #{error}" if error
        coerced
      end

      return [nil, errors.join("; ")] if errors.any?

      [elements, nil]
    end

    def coerce_hash(value)
      return [value, nil] if value.is_a?(Hash)

      [nil, "#{value.inspect} is not a hash"]
    end

    def coerce_enum(attr, value)
      match = attr.values.find { |allowed| allowed.to_s == value.to_s }
      return [match, nil] if match

      [nil, "#{value.inspect} is not one of #{attr.values.map(&:to_s).join(", ")}"]
    end

    # Never let a relative image path resolve outside the content
    # root, however deep the `../` chain is. Existence is checked only
    # after the containment check so a crafted path never learns whether
    # something outside the root exists.
    def coerce_image(value, entry_path:, content_root:)
      return [nil, "#{value.inspect} is not a valid image path"] unless value.is_a?(String)
      unless entry_path && content_root
        return [nil, "image attributes require entry_path: and content_root: to resolve #{value.inspect}"]
      end

      absolute = File.expand_path(value, File.dirname(entry_path))
      root = File.expand_path(content_root)
      project = Andromeda::Assets.project_root

      # Astro resolves `image()` against the entry file and lets it point
      # anywhere in the project -- its own blog example keeps hero images in
      # `src/assets`, outside the collection. So the boundary is the project
      # (or the collection, when that lives outside it, as in tests).
      inside = [project, root].any? { |boundary| absolute.start_with?("#{boundary}#{File::SEPARATOR}") }
      return [nil, "#{value.inspect} resolves outside the project"] unless inside
      return [nil, "#{value.inspect} does not exist"] unless File.file?(absolute)

      relative = absolute.start_with?("#{root}#{File::SEPARATOR}") ? absolute.delete_prefix("#{root}#{File::SEPARATOR}") : absolute.delete_prefix("#{project}#{File::SEPARATOR}")
      # The asset reference is pure path arithmetic, so a listing can link an
      # image before the entry itself has been converted; copying the file is
      # the conversion pipeline's job.
      logical = Andromeda::Assets.logical_path(absolute, content_root: root)
      [
        Andromeda::Image.new(
          path: absolute,
          relative_path: relative,
          asset: logical && Andromeda::Assets.marker_for(logical)
        ),
        nil
      ]
    end

    # Astro normalizes `reference("authors")` to `{id, collection}`;
    # the common case in frontmatter is a plain String id, but a
    # Hash form is accepted too so already-normalized data round-trips.
    # Resolving `id` against the actual collection registry happens
    # elsewhere -- this only builds the
    # pointer and checks it names the collection the schema declared.
    def coerce_reference(attr, value)
      case value
      when String
        [Andromeda::Reference.new(collection: attr.collection, id: value), nil]
      when Hash
        id = value["id"] || value[:id]
        return [nil, "reference is missing id: #{value.inspect}"] unless id

        collection = value["collection"] || value[:collection]
        collection = collection&.to_sym
        if collection && collection != attr.collection
          return [nil, "reference collection #{collection.inspect} does not match declared collection #{attr.collection.inspect}"]
        end

        [Andromeda::Reference.new(collection: collection || attr.collection, id: id), nil]
      else
        [nil, "#{value.inspect} is not a valid reference"]
      end
    end
  end
end
