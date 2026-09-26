#!/usr/bin/env bash
# Downloads real Astro content (docs, Starlight, examples) into test/corpus_large
# for `rake test:corpus`. Requires the gh CLI. MIT-licensed upstream projects.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p corpus_large

fetch() {
  local repo=$1 prefix=$2 limit=$3
  # The limit is applied inside --jq rather than with `head`: head closing the
  # pipe early kills gh with SIGPIPE, which pipefail turns into a failed run.
  gh api "repos/$repo/git/trees/main?recursive=1" \
    --jq "[.tree[] | select(.type==\"blob\") | .path | select(startswith(\"$prefix\")) | select(test(\"\\\\.mdx?$\"))] | .[:$limit][]" \
    | while read -r path; do
      out="corpus_large/$(echo "$repo" | tr / _)__$(echo "$path" | tr / _)"
      [ -f "$out" ] || curl -sf "https://raw.githubusercontent.com/$repo/main/$path" -o "$out" || true
    done
}

fetch withastro/starlight docs/src/content/docs/ 80
fetch withastro/docs src/content/docs/en/ 250
fetch withastro/astro examples/ 40
echo "corpus: $(ls corpus_large | wc -l | tr -d ' ') files"
