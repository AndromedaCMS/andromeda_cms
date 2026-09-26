# Corpus smoke-test fixtures

These files are an unmodified subset (22 of 370) of the corpus assembled in
`samples/markdown-rs-poc/work/corpus/` (see that PoC's
`scripts/fetch_corpus.sh`), copied here so `test/corpus_test.rb` can assert
that real-world Astro content parses without raising, without needing the
full 370-file corpus checked out.

- Source repositories: [withastro/docs](https://github.com/withastro/docs),
  [withastro/starlight](https://github.com/withastro/starlight), and
  [withastro/astro](https://github.com/withastro/astro) (the `examples/`
  trees), all MIT licensed.
- Selection: a mix of plain `.md` (blog-style posts, READMEs) and
  MDX-component-heavy `.mdx` files (Starlight's `<Aside>`, `<Tabs>`,
  `<FileTree>`, `<Steps>`, `<Card>`; Astro's own component/JSX docs),
  including `basics/astro-components.mdx` and `reference/astro-syntax.mdx`,
  the two files `samples/satteri-poc/README.md` calls out for the
  `mdxJsxFlowElement` vs. `mdxJsxTextElement` classification difference
  between Sätteri and remark.
- Files are otherwise untouched (original filenames are flattened repo paths,
  matching the naming used by the source corpus fetch script).
