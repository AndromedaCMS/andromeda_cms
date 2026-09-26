# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-09-27

### Fixed

- `Entry#body` returned `nil` in production. Entries there are read from the
  built index, which leaves bodies out, so anything using the raw Markdown --
  a reading-time estimate, a Markdown export -- failed with `NoMethodError`.
  The build now stores each entry's body in its own file (not the index), and
  `Entry#body` reads it from there when needed, the same way `html` works.
  Existing builds pick this up on the next `andromeda:build`.

## [0.1.1] - 2026-09-27

### Fixed

- `andromeda:build` failed with `Andromeda::BuildMissing` when run in
  production mode on a clean checkout -- which is exactly how
  `assets:precompile` runs in a Docker build -- because it listed entries from
  the built index instead of the source files. On a production machine that
  already had a build, the same path would have rewritten every page with an
  empty body. Builds now always read the source files.

## [0.1.0] - 2026-09-27

### Added

- Astro-compatible content collections: entry classes with a schema DSL, an
  Astro-compatible id scheme, and queries (`all`/`find`/`where`/`order`/scopes).
- Markdown and MDX conversion through Sätteri, the engine Astro 7 uses by
  default, with GFM, smart punctuation, github-slugger heading ids and Rouge
  syntax highlighting.
- MDX components rendered as Rails partials, including props, children and
  named slots.
- Frontmatter parsing with Astro-compatible semantics: YAML 1.2 scalars, TOML
  (`+++`), and line numbers preserved for error messages.
- Build pipeline: `andromeda:build` (hooked into `assets:precompile`),
  `andromeda:check`, `andromeda:fix` and `andromeda:clobber`, writing to
  `.andromeda/`; on-demand conversion in development.
- Images referenced from content published through the asset pipeline.
- View helpers: `andromeda_content`, `andromeda_toc`, `andromeda_meta_tags`,
  `andromeda_image_url`.
- Generators: `andromeda:install`, `andromeda:collection`,
  `andromeda:component` and `andromeda:import_astro`.

[0.1.2]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.1.2
[0.1.1]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.1.1
[0.1.0]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.1.0
