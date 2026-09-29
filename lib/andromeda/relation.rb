# frozen_string_literal: true

module Andromeda
  # A small, chainable wrapper around an Array of loaded entries.
  # v0 keeps everything in memory, so there is no query to build up and
  # defer -- every method here just filters/sorts the Array it already has.
  # Deliberately not lazy/Enumerator-based: at v0 scale that would only add
  # indirection without saving any real work.
  class Relation
    include Enumerable

    # @return [Class, nil] the Andromeda::Entry subclass this relation was
    #   built from, so `scope` calls (defined on the class) can be looked up
    #   and re-run when chained off a Relation instead of the class itself.
    attr_reader :entry_class

    # @param records [Array<Andromeda::Entry>]
    # @param entry_class [Class, nil]
    def initialize(records, entry_class: nil)
      @records = records
      @entry_class = entry_class
    end

    def each
      return enum_for(:each) unless block_given?

      @records.each { |record| yield record }
    end

    # @return [Array<Andromeda::Entry>] a defensive copy.
    def to_a
      @records.dup
    end

    # `where(draft: false)` (equality on `data`) or `where { |e| ... }`
    # (arbitrary block) -- both forms Astro's own `getCollection(name,
    # filter)` supports as one argument, split here into two Ruby-idiomatic
    # entry points instead.
    #
    # @param conditions [Hash, nil] Symbol/String keys, matched against
    #   `entry.data`.
    def where(conditions = nil, &block)
      filtered =
        if block
          @records.select(&block)
        elsif conditions
          @records.select { |record| conditions.all? { |key, value| record.data[key.to_sym] == value } }
        else
          @records
        end

      self.class.new(filtered, entry_class: entry_class)
    end

    # @return [Andromeda::Entry, nil]
    def find_by(conditions = nil, &block)
      where(conditions, &block).first
    end

    # `order(:pub_date)` (ascending) or `order(pub_date: :desc)`. Multiple
    # criteria apply left to right, like SQL's `ORDER BY a, b`.
    def order(*criteria)
      keys = criteria.flat_map { |criterion| criterion.is_a?(Hash) ? criterion.to_a : [[criterion, :asc]] }

      # Array#sort is not stable, but JavaScript's is, and an Astro listing
      # sorted by date keeps same-day posts in their original order. The
      # original position breaks every remaining tie so the order is the
      # same here, and the same on every run.
      sorted = @records.each_with_index.sort do |(a, a_index), (b, b_index)|
        compare_by(keys, a, b).nonzero? || a_index <=> b_index
      end

      self.class.new(sorted.map(&:first), entry_class: entry_class)
    end

    # @return [Andromeda::Relation]
    def limit(count)
      self.class.new(@records.first(count), entry_class: entry_class)
    end

    # Skips the first `count` entries, so `offset(10).limit(10)` is the
    # second page of ten.
    #
    # @return [Andromeda::Relation]
    def offset(count)
      self.class.new(@records.drop(count), entry_class: entry_class)
    end

    # @return [Andromeda::Entry, Array<Andromeda::Entry>, nil]
    def first(count = nil)
      count ? @records.first(count) : @records.first
    end

    def count
      @records.size
    end

    def size
      @records.size
    end
    alias length size

    def empty?
      @records.empty?
    end

    # Lets a scope declared on `entry_class` (via `Entry.scope`) be called
    # directly on a Relation, so `Post.published.recent` chains the same way
    # `Post.published` does at the class level.
    def method_missing(name, *args, &block)
      scope = entry_class&.scopes&.[](name)
      return instance_exec(*args, &scope) if scope

      super
    end

    def respond_to_missing?(name, include_private = false)
      !!entry_class&.scopes&.key?(name) || super
    end

    private

    # The first criterion on which `a` and `b` differ decides; 0 if none does.
    def compare_by(keys, a, b)
      keys.each do |attribute, direction|
        # Incomparable values (one side nil) count as a tie, not an error.
        comparison = (a.data[attribute.to_sym] <=> b.data[attribute.to_sym]) || 0
        return direction == :desc ? -comparison : comparison unless comparison.zero?
      end
      0
    end
  end
end
