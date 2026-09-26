# frozen_string_literal: true

class BlogController < ApplicationController
  def index
    @entries = Content::Post.published.order(pub_date: :desc)
  end

  def show
    @entry = Content::Post.find(params[:slug])
  end
end
