# frozen_string_literal: true

module Andromeda
  # Base class so host applications can rescue everything this gem raises.
  class Error < StandardError; end

  # Raised when Markdown or MDX cannot be parsed. Carries the source location so
  # editors and CI logs can point at the offending line rather than the file.
  class SyntaxError < Error
    attr_reader :path, :line, :column, :raw_message

    def initialize(message, path: nil, line: nil, column: nil)
      @path = path
      @line = line
      @column = column
      # Kept so the error can be rebuilt once the path is known without having
      # to strip the location back out of the formatted message.
      @raw_message = message
      super(location ? "#{location}: #{message}" : message)
    end

    # Returns a copy of this error attributed to `path`.
    def at(path)
      self.class.new(raw_message, path: path, line: line, column: column)
    end

    def location
      return nil unless path || line

      [path, line, column].compact.join(":")
    end
  end

  # Raised when the parser itself fails unexpectedly. Sätteri is pre-1.0, so a
  # panic is converted into this instead of aborting the whole Ruby process.
  class ParserError < Error; end

  # Raised by Schema#validate! when frontmatter fails validation. Carries
  # every Schema::Problem found (Zod-style: report everything in one pass)
  # so a fix-and-rerun cycle can address all of them instead of one at a
  # time, and names the offending file when a path is available so the
  # message is actionable straight out of a build log.
  class ValidationError < Error
    attr_reader :problems, :path

    def initialize(problems, path: nil)
      @problems = problems
      @path = path
      lines = problems.map { |problem| path ? "#{path}: #{problem.message}" : problem.message }
      super(lines.join("\n"))
    end
  end

  # Raised by Loader#load when one or more files fail to load (validation
  # failures, syntax errors, duplicate ids). Like ValidationError, this
  # collects everything found across every file in one build rather than
  # stopping at the first bad file, so a fix-and-rerun cycle can address all
  # of them at once instead of playing whack-a-mole one file at a time.
  class LoaderError < Error
    attr_reader :messages

    def initialize(messages)
      @messages = messages
      super(messages.join("\n"))
    end
  end

  # Raised by Entry.find / Andromeda.get_entry when no entry has the given
  # id. Lists near-miss ids (by edit distance) when any are close enough to
  # plausibly be a typo -- e.g. `find("hello-wrold")` should hint at
  # `hello-world` rather than just saying "not found".
  class EntryNotFound < Error
    attr_reader :collection, :id, :candidates

    def initialize(collection:, id:, candidates: [])
      @collection = collection
      @id = id
      @candidates = candidates

      message = "no #{collection.inspect} entry with id #{id.to_s.inspect}"
      hints = near_misses(id.to_s, candidates)
      message += ". Did you mean #{hints.map(&:inspect).join(" or ")}?" unless hints.empty?
      super(message)
    end

    private

    # Only surfaces candidates within a small edit distance -- a long list
    # of unrelated ids would be noise, not a hint.
    def near_misses(id, candidates, max: 3, threshold: 4)
      candidates
        .map { |candidate| [candidate, levenshtein_distance(id, candidate)] }
        .select { |_, distance| distance <= threshold }
        .sort_by { |_, distance| distance }
        .first(max)
        .map(&:first)
    end

    # Classic Wagner-Fischer DP. No gem dependency for what is, at v0 scale
    # (everything held in memory), a handful of short string comparisons.
    def levenshtein_distance(a, b)
      return b.length if a.empty?
      return a.length if b.empty?

      costs = (0..b.length).to_a
      a.each_char.with_index(1) do |char_a, i|
        last_diagonal = costs[0]
        costs[0] = i
        b.each_char.with_index(1) do |char_b, j|
          old_cost = costs[j]
          costs[j] = if char_a == char_b
                       last_diagonal
                     else
                       [costs[j] + 1, costs[j - 1] + 1, last_diagonal + 1].min
                     end
          last_diagonal = old_cost
        end
      end
      costs.last
    end
  end

  # Raised by Andromeda::Pipeline#fetch/#collection_index in production mode
  # when a request asks for an entry/collection that
  # `andromeda:build` has never converted -- production never converts on
  # demand, so this is the "you forgot to build" error rather than a
  # transient failure, and the message says exactly what fixes it.
  class BuildMissing < Error
    attr_reader :collection, :id, :file_path

    def initialize(collection:, id: nil, file_path: nil)
      @collection = collection
      @id = id
      @file_path = file_path

      target = id ? "#{collection}/#{id}" : collection.to_s
      source = file_path ? " (source: #{file_path})" : ""
      super(
        "no converted output for #{target.inspect}#{source} -- run `bin/rails andromeda:build` to convert " \
        "content into .andromeda/ (this also happens automatically as part of `assets:precompile`)"
      )
    end
  end

  # Raised by Andromeda::Pipeline#build_collection/.build_all (and
  # #refresh_collection in development) when one or more entries fail to
  # convert -- a schema problem, an unregistered MDX component, a syntax
  # error, and so on. Like Andromeda::LoaderError, every problem found is
  # collected first and raised together, so a build reports everything in
  # one pass instead of a fix-and-rerun cycle one file at a time.
  class BuildError < Error
    attr_reader :messages

    def initialize(messages)
      @messages = messages
      super(messages.join("\n"))
    end
  end

  # Raised by Andromeda.get_collection / Andromeda.get_entry when no Entry
  # subclass has registered the given collection name (see
  # Andromeda::Registry) -- most often because its class has not been
  # loaded yet in a development boot where app/ is not eager loaded.
  class UnknownCollection < Error
    def initialize(name)
      super(
        "no collection registered for #{name.inspect} -- does an Andromeda::Entry " \
        "subclass call `collection #{name.inspect}, base: ...`? In development this " \
        "class must be loaded first; see Andromeda::Registry.discover"
      )
    end
  end
end
