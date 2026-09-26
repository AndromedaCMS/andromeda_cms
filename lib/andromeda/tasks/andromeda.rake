# frozen_string_literal: true

namespace :andromeda do
  desc "Convert every content file into .andromeda/"
  task build: :environment do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      results = Andromeda::Pipeline.build_all
    rescue Andromeda::BuildError => e
      # Failing the task (rather than warning) is what keeps a broken deploy
      # from shipping content that silently lost a page.
      warn e.message
      abort "andromeda:build failed"
    end

    entries = results.sum(&:converted)
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    puts "andromeda:build converted #{entries} entries in #{results.size} collection(s) (#{elapsed}ms)"
  end

  desc "Remove converted content"
  task clobber: :environment do
    Andromeda::Store.new.clobber!
    puts "andromeda:clobber removed #{Andromeda.config.build_path}"
  end

  desc "Report content problems without writing anything (for CI)"
  task check: :environment do
    problems = Andromeda::Check.run

    if problems.empty?
      puts "andromeda:check found no problems"
    else
      problems.each { |problem| warn problem }
      abort "andromeda:check found #{problems.size} problem(s)"
    end
  end

  desc "Rewrite non-snake_case frontmatter keys in place"
  task fix: :environment do
    changes = Andromeda::Fix.run

    if changes.empty?
      puts "andromeda:fix found nothing to change"
    else
      changes.each { |change| puts change }
      puts "andromeda:fix updated #{changes.size} file(s)"
    end
  end
end

# Mirrors how tailwindcss-rails attaches itself, so a deploy that already runs
# assets:precompile (every Rails 8 Dockerfile does) needs no extra step.
Rake::Task["assets:precompile"].enhance(["andromeda:build"]) if Rake::Task.task_defined?("assets:precompile")
Rake::Task["assets:clobber"].enhance(["andromeda:clobber"]) if Rake::Task.task_defined?("assets:clobber")
