# frozen_string_literal: true

Rails.application.routes.draw do
  resources :blog, only: %i[index show], param: :slug
end
