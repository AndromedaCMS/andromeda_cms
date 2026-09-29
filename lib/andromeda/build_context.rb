# frozen_string_literal: true

module Andromeda
  # What the current thread is doing on Andromeda's behalf, for code that
  # runs *inside* a conversion but cannot be told so directly: a component
  # partial rendered into an entry's HTML calls the same `Entry.find` and
  # `andromeda_image_url` a request-time view does, yet both must behave
  # differently while the output is being produced.
  #
  # Thread-local because a build or a development request converts on one
  # thread, and another thread serving requests at the same time must keep
  # seeing the built index.
  module BuildContext
    BUILD_KEY = :andromeda_build_source_entries
    CONVERTING_KEY = :andromeda_converting

    module_function

    # Marks the block as an `andromeda:build`. Queries made during it read
    # source files instead of `_index.json`, which is still the previous
    # build's (or absent) until each collection finishes -- so a component
    # that looks up another entry would otherwise miss one that has not been
    # converted yet. Each collection is loaded once per build and shared.
    #
    # Nested calls reuse the outer build's cache.
    def building
      return yield if building?

      Thread.current[BUILD_KEY] = {}
      begin
        yield
      ensure
        Thread.current[BUILD_KEY] = nil
      end
    end

    def building?
      !Thread.current[BUILD_KEY].nil?
    end

    # @param entry_class [Class] an Andromeda::Entry subclass.
    # @return [Array<Andromeda::Entry>] the block's result, cached for the
    #   rest of the build.
    def source_entries(entry_class)
      cache = Thread.current[BUILD_KEY]
      return yield if cache.nil?

      cache[entry_class] ||= yield
    end

    # Marks the block as rendering an entry's body into stored HTML. Anything
    # that would bake a final asset URL into it must emit a marker instead:
    # the digest is only known once `assets:precompile` runs, after the build.
    #
    # A component can ask another entry for its HTML, which converts that
    # entry inside this one; the stack of entries being converted is what
    # stops two entries whose components show each other from recursing
    # forever.
    #
    # @param label [String] identifies the entry, e.g. "blog/hello-world".
    # @raise [Andromeda::Error] if `label` is already being converted.
    def converting(label)
      stack = Thread.current[CONVERTING_KEY] ||= []
      if stack.include?(label)
        raise Andromeda::Error, "circular conversion: #{[*stack.drop_while { |l| l != label }, label].join(' -> ')} " \
                                "-- a component renders the HTML of an entry that renders this one"
      end

      stack.push(label)
      begin
        yield
      ensure
        stack.pop
      end
    end

    def converting?
      !(Thread.current[CONVERTING_KEY] || []).empty?
    end
  end
end
