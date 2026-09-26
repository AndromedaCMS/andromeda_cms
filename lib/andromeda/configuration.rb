# frozen_string_literal: true

module Andromeda
  # Settings a host application may override, all of them paths or names that
  # only the application knows. Anything that would change how content is
  # interpreted (the parser, GFM, smart punctuation) is deliberately absent:
  # those follow Astro's defaults so copied content behaves the same, and a
  # knob here would quietly break that promise.
  class Configuration
    # Where content files live, relative to the application root.
    attr_accessor :content_path

    # Namespace of the entry classes, so an app that already defines `Content`
    # can move them aside.
    attr_accessor :entry_namespace

    # Directory holding the partials MDX components resolve to.
    attr_accessor :components_path

    # Where `andromeda:build` writes converted content. Hidden and ignored by
    # git, like Astro's own `.astro/`.
    attr_accessor :build_path

    # Rouge theme used for code blocks; the default mirrors the Shiki theme
    # Astro ships with so copied content keeps roughly the same look.
    attr_accessor :highlight_theme

    # `:development` (convert on demand, checking each source file's digest)
    # or `:production` (read-only; `Andromeda::BuildMissing` if
    # `andromeda:build` never ran) -- see Andromeda::Pipeline.
    #
    # This has to be decidable without Rails at all, so it is a plain
    # setting rather than something inferred from
    # `Rails.env`. `:development` is the sane default for that
    # Rails-less case -- a `bin/rails runner` script or this gem's own test
    # suite would otherwise get `BuildMissing` for every fixture unless it
    # remembered to build first. The Railtie sets this explicitly from
    # `Rails.env` at boot, so a real app never relies on this default.
    attr_accessor :mode

    # The boundary an image path may not escape, and the base every relative
    # path is resolved against. Defaults to the Rails root at boot; settable
    # so a non-Rails script (or a test importing into a scratch directory)
    # can point the gem at a different tree.
    attr_writer :project_root

    # Resolved on every call rather than memoized: code that runs before
    # Rails has set its root (a gem loaded early, a rake task) would otherwise
    # pin the working directory for the rest of the process.
    def project_root
      File.expand_path(@project_root || rails_root || Dir.pwd)
    end

    def rails_root
      ::Rails.root.to_s if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
    end
    private :rails_root

    def initialize
      @content_path = "app/content"
      @entry_namespace = "Content"
      @components_path = "app/views/content_components"
      @build_path = ".andromeda"
      @highlight_theme = "github.dark"
      @mode = :development
    end

    # Entry classes live under the namespace, mirroring Rails' own mapping of
    # `Content::Post` to `app/models/content/post.rb`.
    def entry_class_path
      File.join("app/models", entry_namespace.gsub("::", "/").downcase)
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    # Test suites need a way back to a known state; applications configure once
    # at boot and never call this.
    def reset_config!
      @config = Configuration.new
    end
  end
end
