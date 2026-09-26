# Contributing

**Andromeda is open source, but not open contribution.**

The code is MIT licensed: use it, fork it, change it, ship it. What this
project does not do is take patches into its own implementation. That keeps the
copyright in one place, which in turn keeps relicensing, redistribution and
long-term maintenance decisions simple — the same reasoning
[SQLite](https://www.sqlite.org/copyright.html) gives for its own policy.

So pull requests are generally closed unfixed, and that is not a judgement on
the code in them. Please do not spend an afternoon on a patch expecting it to be
merged.

## What helps most

**Bug reports.** They are the highest-value contribution here, and they are
always welcome. A good one includes:

- the versions of Ruby, Rails and `andromeda_cms`
- the content file that triggers it, reduced to the smallest thing that still
  fails (frontmatter plus a few lines of body is usually enough)
- what you expected, and what happened, including the full error message
- for a compatibility problem: what Astro does with the same file

**Compatibility gaps.** Content that works in Astro and does not work here is a
bug, even if the error message looks reasonable. Say which Astro version the
content came from.

**Documentation that is wrong or missing.** Point at the page and say what was
confusing; that is enough.

**Ideas.** Open an issue describing the problem you hit rather than the
implementation you have in mind — the problem is the part that is hard to
guess from the outside.

## What to expect

Issues are read. Not every one becomes a change: this gem deliberately keeps a
small surface, and compatibility with Astro's behaviour outranks new options.
When something is declined, the issue will say why.

## Forking

Forking is a legitimate outcome, not a hostile one. If this project will not go
where you need it to go, the MIT licence exists precisely so you can take it
there yourself.
