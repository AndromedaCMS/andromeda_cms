# Astro blog example (fixture)

`src/content/blog/*`, `src/content.config.ts` and `src/components/HeaderLink.astro`
are unmodified copies from [withastro/astro](https://github.com/withastro/astro)
`examples/blog` (MIT). They are the acceptance input for
`test/import_astro_end_to_end_test.rb`: content written for Astro has to import
and validate without being touched.

`src/assets/*.jpg` are tiny stand-ins rather than the real photographs — the
tests only assert that the files referenced by frontmatter exist and are
published, and shipping ~200KB of JPEGs in a gem's test suite buys nothing.
