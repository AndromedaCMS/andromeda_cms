# frozen_string_literal: true

require "psych"
require "tomlrb"
require "date"
require "time"
require "stringio"

module Andromeda
  # Splits and parses `---`/`+++` frontmatter, matching how Astro itself
  # handles it: Astro strips frontmatter *before* handing the rest of the
  # document to its Markdown engine (`packages/internal-helpers/src/frontmatter.ts`),
  # rather than letting the Markdown parser recognize a frontmatter node. We
  # do the same here so Sätteri (which has no built-in notion of `+++` TOML
  # blocks) never has to see either fence.
  module Frontmatter
    # Recognized fences and the format they select, in the order Astro checks
    # them (`getFrontmatterParser` in frontmatter.ts).
    FENCES = { "---" => :yaml, "+++" => :toml }.freeze

    # Optional BOM, then any number of purely-blank lines, before the fence
    # itself. Mirrors the two branches of Astro's `frontmatterRE`
    # (`^\uFEFF?` and `^\s*\n`) collapsed into one pass: BOM and leading blank
    # lines are both tolerated, but only right at the top of the file -- once
    # a non-blank line is seen, no `---`/`+++` after it is a fence.
    LEADING_RE = /\A\uFEFF?(?:[ \t]*\r?\n)*/

    # Psych resolves plain scalars by YAML 1.1 rules; js-yaml, which Astro
    # uses, follows YAML 1.2's core schema. The two disagree on values that
    # really do appear in hand-written frontmatter, and a silent disagreement
    # is worse than an error: `time: 12:30` becoming the integer 45000 passes
    # every schema check and then displays nonsense. Each rule below mirrors
    # what js-yaml 4 does with the same plain scalar.
    class ScalarScanner < Psych::ScalarScanner
      # 1.1-only booleans; 1.2 keeps them as strings.
      YAML_1_1_ONLY_BOOL = /\A(?:[Yy]es|YES|[Nn]o|NO|[Oo]n|ON|[Oo]ff|OFF|[Yy]|[Nn])\z/
      # 1.1 base-60 (`1:30`) and comma-grouped (`1,000`) numbers; 1.2 has
      # neither, so these stay strings.
      YAML_1_1_ONLY_NUMBER = /\A[-+]?[0-9][0-9_]*(?:(?::[0-5]?[0-9])+|(?:,[0-9_]+)+)(?:\.[0-9_]*)?\z/
      # 1.1 reads a leading zero as octal (`010` is 8); 1.2 reads it as decimal.
      LEADING_ZERO_DECIMAL = /\A[-+]?0[0-9_]+\z/
      # 1.2's explicit octal prefix, unknown to Psych.
      OCTAL = /\A[-+]?0o[0-7_]+\z/
      # 1.2 accepts an exponent without a decimal point (`1e3`); Psych does not.
      EXPONENT_FLOAT = /\A[-+]?(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9_]+)[eE][-+]?[0-9]+\z/

      def tokenize(string)
        case string
        when YAML_1_1_ONLY_BOOL, YAML_1_1_ONLY_NUMBER then string
        when LEADING_ZERO_DECIMAL then Integer(string.delete("_"), 10)
        when OCTAL then Integer(string.delete("_"))
        when EXPONENT_FLOAT then Float(normalize_float(string.delete("_")))
        else super
        end
      end

      private

      # Ruby's Float() rejects the `1.e3` and `.5e3` spellings YAML allows.
      def normalize_float(string)
        string.sub(/\.(?=[eE])/, ".0").sub(/\A([-+]?)\./, "\\10.")
      end
    end

    # Restricts `!!` tags to Date/Time (matching js-yaml's default schema,
    # which also has no notion of arbitrary Ruby classes) while still
    # permitting the two classes plain `YYYY-MM-DD`/timestamp scalars resolve
    # to, so unquoted dates round-trip instead of raising
    # Psych::DisallowedClass.
    class ClassLoader < Psych::ClassLoader::Restricted
      def initialize
        super(%w[Date Time], [])
      end

      public :load
    end

    # Plain (non-"safe") visitor so anchors/aliases resolve instead of
    # raising -- js-yaml allows them by default, and copied Astro content may
    # rely on them.
    class ToRuby < Psych::Visitors::ToRuby
      def initialize
        class_loader = ClassLoader.new
        super(ScalarScanner.new(class_loader), class_loader)
      end
    end

    module_function

    # Separates a leading frontmatter block from the rest of the document.
    #
    # @param source [String] raw file contents (may be CRLF, may start with a
    #   BOM).
    # @return [Array(String, Symbol, String), Array(nil, nil, String)]
    #   `[frontmatter_text, format, body]` when a fence is found at the very
    #   start of the document, or `[nil, nil, source]` otherwise -- including
    #   when a `---`/`+++`-looking line is never closed, since that is
    #   indistinguishable from a document that simply starts with a thematic
    #   break (Astro's own regex only recognizes it as frontmatter once a
    #   matching closing fence is found too).
    def split(source)
      leading = LEADING_RE.match(source)[0]
      rest = source[leading.length..]

      fence, format = FENCES.find { |candidate, _| rest.start_with?(candidate) }
      return [nil, nil, source] unless fence

      after_fence = rest[fence.length..]
      # The opening fence must be alone on its line (trailing spaces/tabs are
      # tolerated, matching how editors sometimes leave them). Requiring this
      # -- rather than letting the fence appear mid-line, which Astro's own
      # regex technically permits -- is what keeps a value like
      # `title: "a --- b"` from ever being mistaken for a fence.
      open_eol = after_fence.match(/\A[ \t]*\r?\n/)
      return [nil, nil, source] unless open_eol

      content_start = leading.length + fence.length + open_eol[0].length
      remainder = source[content_start..]

      # Non-greedy scan for the first line consisting only of the *same*
      # fence: this is what makes a `---` thematic break later in the body
      # inert (it is never reached -- the frontmatter region has already
      # closed by the first matching fence line) and lets an unterminated
      # block fall through to "no frontmatter" below.
      close_re = /^[ \t]*#{Regexp.escape(fence)}[ \t]*(?:\r?\n|\z)/
      close_match = close_re.match(remainder)
      return [nil, nil, source] unless close_match

      frontmatter_text = remainder[0...close_match.begin(0)]
      region_end = content_start + close_match.end(0)

      # Replace the whole fenced region (both fence lines plus the content
      # between them) with the same number of blank lines it occupied, so
      # every line in `body` keeps its original line number -- callers hand
      # `body` to Andromeda::Parser, and parse errors/positions must point at
      # the real file line, not a line shifted by however long the
      # frontmatter was.
      lines_in_region = source[0...region_end].count("\n") - leading.count("\n")
      body = leading + ("\n" * lines_in_region) + source[region_end..]

      [frontmatter_text, format, body]
    end

    # Parses `source`'s frontmatter (if any) and returns `[data, body]`.
    #
    # `data` always has String keys exactly as written in the file -- no
    # snake_case normalization here. Keys are normalized by rewriting files
    # at import time (`andromeda:import_astro`); this layer only has to deal
    # with whatever is currently on disk, camelCase leftovers included, which
    # is what `non_snake_case_keys` is for.
    #
    # @param source [String] raw file contents.
    # @param path [String, nil] attributed on a raised SyntaxError.
    # @return [Array(Hash, String)]
    # @raise [Andromeda::SyntaxError] on malformed YAML/TOML.
    def parse(source, path: nil)
      frontmatter_text, format, body = split(source)
      return [{}, body] if format.nil?

      # 1-based line number of the first line of `frontmatter_text` within
      # the *original* `source` -- every error location below is this plus
      # an offset relative to `frontmatter_text` alone, since Psych/tomlrb
      # only ever see the extracted snippet.
      content_start_line = LEADING_RE.match(source)[0].count("\n") + 2

      data =
        case format
        when :yaml then parse_yaml(frontmatter_text, path: path, content_start_line: content_start_line)
        when :toml then parse_toml(frontmatter_text, path: path, content_start_line: content_start_line)
        end

      [data || {}, body]
    end

    # @param data [Hash] frontmatter data as returned by `parse`.
    # @return [Array<String>] top-level keys that are not snake_case (e.g.
    #   `pubDate`, `hero-image`), for `andromeda:check` to report.
    def non_snake_case_keys(data)
      data.keys.grep(String).reject { |key| snake_case?(key) }
    end

    # Lowercase ASCII letters/digits in underscore-separated segments, with
    # no leading/trailing/doubled underscore. Deliberately ASCII-only: a
    # non-ASCII key (or any key containing an uppercase or symbol character)
    # is exactly the kind of thing `andromeda:check` should flag, since it
    # cannot have come from our own snake_case rewriter.
    SNAKE_CASE_RE = /\A[a-z0-9]+(?:_[a-z0-9]+)*\z/
    private_constant :SNAKE_CASE_RE

    def snake_case?(key)
      key.match?(SNAKE_CASE_RE)
    end
    private_class_method :snake_case?

    def parse_yaml(text, path:, content_start_line:)
      return {} if text.strip.empty?

      node = Psych.parse(text)
      return {} if node.nil?

      reject_alias_explosion!(node, path: path, content_start_line: content_start_line)
      ToRuby.new.accept(node) || {}
    rescue Psych::SyntaxError => e
      # Psych's own #line/#column are 0-based and relative to `text` (the
      # extracted frontmatter snippet), not the file Psych never saw -- shift
      # them onto the real file so the raised error reads like every other
      # Andromeda::SyntaxError (`path:line:column: message`).
      raise syntax_error(psych_message(e), path: path, content_start_line: content_start_line,
                                            relative_line: e.line, relative_column: e.column)
    end
    private_class_method :parse_yaml

    def parse_toml(text, path:, content_start_line:)
      return {} if text.strip.empty?

      # Not calling the public Tomlrb.parse: it rescues Racc::ParseError
      # itself and re-raises as Tomlrb::ParseError carrying only a message,
      # which throws away the scanner's position along with it. Driving the
      # scanner/parser directly keeps that position reachable below.
      scanner = Tomlrb::Scanner.new(StringIO.new(text))
      parser = Tomlrb::Parser.new(scanner)
      normalize_toml_dates(parser.parse.output)
    rescue Racc::ParseError, Tomlrb::ParseError, ArgumentError => e
      relative_line, relative_column = tomlrb_error_location(scanner, text)
      raise syntax_error(e.message, path: path, content_start_line: content_start_line,
                                     relative_line: relative_line, relative_column: relative_column)
    end
    private_class_method :parse_toml

    # tomlrb represents TOML's date-only and offset-less-datetime types with
    # its own Tomlrb::LocalDate/LocalDateTime (only offset datetimes come
    # back as a plain Time) -- neither is a Date or Time, so schema code
    # written against `z.coerce.date()`-style expectations would have
    # to special-case tomlrb just to call `.year` on them. Walk the parsed
    # tree once and swap them for the real thing a local date/date-time
    # naturally maps to.
    def normalize_toml_dates(value)
      case value
      when Hash
        value.transform_values { |v| normalize_toml_dates(v) }
      when Array
        value.map { |v| normalize_toml_dates(v) }
      when Tomlrb::LocalDate
        Date.new(value.year, value.month, value.day)
      when Tomlrb::LocalDateTime
        value.to_time
      else
        value
      end
    end
    private_class_method :normalize_toml_dates

    # tomlrb's generated (Racc) parser tracks no token-start positions at
    # all, only the underlying StringScanner's current byte offset -- which,
    # by the time the parser rejects a token, already sits *after* that
    # token. So the line this resolves to is exact (the offending token is
    # still on it), but the column is best-effort: it points just past the
    # token rather than at its start. That is enough to satisfy "readable
    # without context" without pretending to a precision tomlrb doesn't have.
    def tomlrb_error_location(scanner, text)
      pos = scanner.instance_variable_get(:@ss)&.pos
      return [0, 0] unless pos

      head = text.byteslice(0, pos) || text
      last_newline = head.rindex("\n")
      line = head.count("\n")
      column = last_newline ? pos - last_newline - 1 : pos
      [line, column]
    end
    private_class_method :tomlrb_error_location

    # Frontmatter may use anchors and aliases, but nested aliases multiply: a
    # few hundred bytes can describe hundreds of millions of values
    # ("billion laughs"). Psych shares the repeated objects, so parsing is
    # cheap; writing the entry to JSON is where every copy gets materialized
    # and the build runs out of memory. Counting the expanded size on the
    # node tree -- where each anchor's size is computed once -- catches that
    # before anything is expanded. No real frontmatter comes close.
    MAX_EXPANDED_NODES = 100_000
    private_constant :MAX_EXPANDED_NODES

    def reject_alias_explosion!(document, path:, content_start_line:)
      expanded_size(document, {}) do |node|
        raise syntax_error("aliases expand to more than #{MAX_EXPANDED_NODES} values",
                           path: path, content_start_line: content_start_line,
                           relative_line: node.start_line, relative_column: node.start_column)
      end
    end
    private_class_method :reject_alias_explosion!

    # Number of values `node` stands for once every alias is expanded.
    # `sizes` remembers each anchor's total, so an alias costs a lookup
    # rather than a second walk. Yields the first node over the limit.
    def expanded_size(node, sizes, &over_limit)
      size =
        if node.is_a?(Psych::Nodes::Alias)
          sizes.fetch(node.anchor, 1)
        else
          node.children.to_a.sum(1) { |child| expanded_size(child, sizes, &over_limit) }
        end
      sizes[node.anchor] = size if !node.is_a?(Psych::Nodes::Alias) && node.respond_to?(:anchor) && node.anchor
      yield node if size > MAX_EXPANDED_NODES

      size
    end
    private_class_method :expanded_size

    def syntax_error(message, path:, content_start_line:, relative_line:, relative_column:)
      Andromeda::SyntaxError.new(
        message,
        path: path,
        line: content_start_line + relative_line,
        column: relative_column + 1
      )
    end
    private_class_method :syntax_error

    # Psych's message is prefixed with "(<unknown>): " when it has no
    # filename of its own (we never give it one, since it only ever sees the
    # extracted snippet) -- strip that so it doesn't read like a second,
    # bogus path segment next to the one Andromeda::SyntaxError adds.
    def psych_message(error)
      error.message.sub(/\A\(<unknown>\):\s*/, "")
    end
    private_class_method :psych_message
  end
end
