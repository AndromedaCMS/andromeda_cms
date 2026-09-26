# frozen_string_literal: true

module Content
  class Post < Andromeda::Entry
    collection :blog, base: "app/content/blog", pattern: "**/*.{md,mdx}"

    attribute :title, :string, required: true
    attribute :pub_date, :date, required: true
    attribute :draft, :boolean, default: false
    attribute :tags, :array, of: :string, default: []
    attribute :hero_image, :image

    scope :published, -> { where(draft: false) }
  end
end
