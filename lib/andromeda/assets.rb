# frozen_string_literal: true

require "fileutils"

module Andromeda
  # Publishes images that live next to content so the asset pipeline can serve
  # them.
  #
  # Adding `app/content` to Propshaft's load path would be shorter, but
  # Propshaft serves *every* file in a load path — the Markdown sources
  # themselves would become public URLs. Copying only the referenced images
  # into `app/assets/builds/andromeda/` keeps the content directory private and
  # mirrors how tailwindcss-rails treats `app/assets/builds`.
  module Assets
    # Relative to `app/assets/builds`, and therefore also the prefix of the
    # logical asset path the view helpers resolve.
    DIRECTORY = "andromeda"

    module_function

    # Copies `source` under the builds directory and returns its logical path
    # (what `asset_path` takes), or nil when the file is not a publishable
    # asset under the content root.
    #
    # @param source [String] absolute path to a file inside the content root.
    # @param content_root [String] the collection's base directory.
    # @return [String, nil] e.g. "andromeda/blog/post/cover.png".
    def publish(source, content_root:)
      logical = logical_path(source, content_root: content_root)
      return nil if logical.nil?

      return logical if asset_pipeline_path(File.expand_path(source))

      destination = File.join(builds_root, logical)
      FileUtils.mkdir_p(File.dirname(destination))
      # Copying only when the content changed keeps `andromeda:build` cheap on
      # image-heavy sites, where the copy would otherwise dominate the run.
      FileUtils.cp(source, destination) unless identical?(source, destination)
      logical
    end

    # Conversion cannot know an image's final URL: Propshaft only learns the
    # digest when `assets:precompile` runs, which is *after* `andromeda:build`
    # (it depends on it), and in development the load path is indexed at boot.
    # So the stored HTML carries this marker and the view resolves it, which
    # costs one gsub per render and keeps digests correct in both environments.
    MARKER = "andromeda-asset:"

    def marker_for(logical_path)
      "#{MARKER}#{logical_path}"
    end

    # @param html [String] stored HTML, possibly containing markers.
    # @return [String] the same HTML with every marker replaced by a real URL.
    def resolve(html)
      return html unless html.include?(MARKER)

      html.gsub(/#{Regexp.escape(MARKER)}([^"'\s)]+)/) { url_for(Regexp.last_match(1)) }
    end

    # @return [String] a URL for a logical path, digest-stamped when the asset
    #   pipeline is available and a plain /assets path otherwise.
    def url_for(logical_path)
      if defined?(::ActionController::Base)
        ::ActionController::Base.helpers.asset_path(logical_path)
      else
        File.join("/assets", logical_path)
      end
    rescue StandardError
      # An image that has not been indexed yet (a fresh copy in development,
      # or a precompile that has not run) must not take the whole page down.
      File.join("/assets", logical_path)
    end

    # Whether the asset pipeline can serve `logical_path`. `url_for` falls
    # back to a plain /assets path for anything it cannot find, so without
    # this check a typo only shows up as a 404 in production.
    #
    # This looks at the files directly instead of calling `load_path.find`:
    # Propshaft memoizes its file list on the first lookup, and the same load
    # path is later used by assets:precompile. Asking it during andromeda:build
    # would hide every file written afterwards (tailwind.css from
    # tailwindcss:build, images copied by `publish`) from the precompile.
    #
    # @return [Boolean, nil] nil when there is no Propshaft load path to ask
    #   (no asset pipeline, or Sprockets), so callers can skip the check.
    def exists?(logical_path)
      load_path = pipeline_load_path
      return nil if load_path.nil?

      path = logical_path.to_s
      return false if path.start_with?("/") || path.split("/").include?("..")
      return false if File.basename(path).start_with?(".")

      load_path.paths.any? { |directory| File.file?(File.join(directory.to_s, path)) }
    end

    def pipeline_load_path
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

      assets = ::Rails.application.assets
      assets.respond_to?(:load_path) && assets.load_path.respond_to?(:paths) ? assets.load_path : nil
    rescue StandardError
      nil
    end

    def logical_path(source, content_root:)
      source = File.expand_path(source)
      root = File.expand_path(content_root)
      project = project_root

      # Nothing outside the project (or the content root, when a collection
      # lives elsewhere) may be published: a `../` chain in a content file
      # must not expose an arbitrary file on the machine.
      inside = [project, root].any? { |boundary| source.start_with?("#{boundary}#{File::SEPARATOR}") }
      return nil unless inside

      if source.start_with?("#{root}#{File::SEPARATOR}")
        File.join(DIRECTORY, File.basename(root), source.delete_prefix("#{root}#{File::SEPARATOR}"))
      elsif (asset_relative = asset_pipeline_path(source))
        asset_relative
      else
        # Somewhere else in the project (Astro's own example keeps hero
        # images in `src/assets`): mirrored under the build directory so it
        # still gets a digest, with the project-relative path kept to avoid
        # collisions between same-named files.
        File.join(DIRECTORY, "project", source.delete_prefix("#{project}#{File::SEPARATOR}"))
      end
    end

    # A file the asset pipeline already serves needs no copy -- returning its
    # logical path lets `asset_path` digest the original in place.
    def asset_pipeline_path(source)
      assets_root = File.join(project_root, "app/assets")
      return nil unless source.start_with?("#{assets_root}#{File::SEPARATOR}")

      relative = source.delete_prefix("#{assets_root}#{File::SEPARATOR}")
      # Propshaft's load path is each directory under app/assets, so the
      # first segment (images/, stylesheets/, builds/, ...) is not part of
      # the logical path -- except for files sitting directly in app/assets.
      relative.include?(File::SEPARATOR) ? relative.split(File::SEPARATOR, 2).last : relative
    end

    def project_root
      Andromeda.config.project_root
    end

    def builds_root
      File.join(project_root, "app/assets/builds")
    end

    # Compares bytes, not timestamps: a checkout or an extracted archive can
    # give a changed image an old mtime, and a same-sized edit would then
    # never be copied. The size check keeps the common case cheap.
    def identical?(source, destination)
      File.exist?(destination) && File.size(source) == File.size(destination) &&
        FileUtils.compare_file(source, destination)
    end
  end
end
