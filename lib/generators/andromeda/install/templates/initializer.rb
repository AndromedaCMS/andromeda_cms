# frozen_string_literal: true

# Uncomment and edit any of these to override Andromeda's defaults -- see
# Andromeda::Configuration for the full description of each setting.
Andromeda.configure do |config|
  # Where content files live, relative to the application root.
  # config.content_path = "app/content"

  # Namespace of the entry classes -- `Content::Post` lives at
  # app/models/content/post.rb by default. Change this if your app already
  # defines a top-level `Content`.
  # config.entry_namespace = "Content"

  # Directory holding the partials MDX components resolve to.
  # config.components_path = "app/views/content_components"

  # Where `andromeda:build` writes converted content. Hidden and ignored by
  # git and Docker, like Astro's own .astro/.
  # config.build_path = ".andromeda"

  # Rouge theme used for code blocks; the default mirrors the Shiki theme
  # Astro ships with.
  # config.highlight_theme = "github.dark"

  # :development (convert on demand, checking each source file's digest) or
  # :production (read-only; raises Andromeda::BuildMissing if
  # `andromeda:build` never ran). The Railtie sets this from Rails.env at
  # boot, so overriding it here is rarely needed.
  # config.mode = :development
end
