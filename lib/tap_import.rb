# This code is free software; you can redistribute it and/or modify it under
# the terms of the new BSD License.
#
# Copyright (c) 2017, Sebastian Staudt

require 'repository_import'

module TapImport

  include RepositoryImport

  ALIAS_REGEX = /^(?:Library\/)?Aliases\/(.+?)$/

  def analyze_commits(log_params)
    reset_head
    log_cmd = "log --format=format:'%H%x00%ct%x00%aE%x00%aN%x00%s' --name-status --no-merges #{log_params}"

    commits = git(log_cmd).split /\n\n/
    commit_progress = 0
    commit_count = commits.size
    commits.each_slice(100) do |commit_batch|
      commit_batch.each do |commit|
        info, *formulae = commit.lines
        sha, timestamp, email, name, subject = info.strip.split "\x00"
        rev = Revision.find_or_initialize_by sha: sha
        self.revisions << rev
        rev.author = Author.find_or_initialize_by email: email
        self.authors << rev.author
        rev.author.name = name
        rev.author.save!
        rev.date = timestamp.to_i
        rev.subject = subject
        formulae.each do |formula|
          status, name = formula.split
          next unless name =~ formula_regex
          name = File.basename $~[1], '.rb'
          formula = self.formulae.where(name: name).first
          next if formula.nil?
          formula.revisions << rev
          formula.date = rev.date if formula.date.nil? || rev.date > formula.date
          formula.save!
          if status == 'M' || status =~ /R\d\d\d/
            rev.updated_formulae << formula
          elsif status == 'A'
            rev.added_formulae << formula
          elsif status == 'D'
            rev.removed_formulae << formula
          end
        end
        rev.save!
      end

      save!

      commit_progress += commit_batch.size
      Rails.logger.debug "Analyzed #{commit_progress} of #{commit_count} revisions."
    end
  end

  def clone_or_pull(reset = true)
    main_repo.clone_or_pull unless full?

    super
  end

  def repo
    Repository.core.extend RepositoryImport
  end

  def find_formula(file)
    file = file.to_s
    file.gsub! /(?<=[^\\])\+/, '\\\\+'
    file = file + '.rb' unless file.end_with? '.rb'
    git("ls-files | grep -E '(^|/)#{file}'").lines.first.strip rescue nil
  end

  def formulae_info(formulae, backward_compat = false)
    tmp_file = Tempfile.new 'braumeister-import'

    repositories = ([ Repository.core, self ] + Repository.all).uniq

    pid = fork do
      begin
        require 'sandbox/backtick'
        require 'sandbox/io_popen'

        $homebrew_path = main_repo.path
        $LOAD_PATH.unshift $homebrew_path
        $LOAD_PATH.unshift File.join($homebrew_path, 'Library', 'Homebrew')
        ENV['HOMEBREW_BREW_FILE'] = File.join $homebrew_path, 'bin', 'brew'
        ENV['HOMEBREW_CACHE'] = File.join $homebrew_path, 'Cache'
        ENV['HOMEBREW_CELLAR'] = File.join $homebrew_path, 'Cellar'
        ENV['HOMEBREW_LIBRARY'] = File.join $homebrew_path, 'Library'
        ENV['HOMEBREW_OSX_VERSION'] = '10.11'
        ENV['HOMEBREW_PREFIX'] = $homebrew_path
        ENV['HOMEBREW_REPOSITORY'] = File.join $homebrew_path, '.git'

        Object.send(:remove_const, :Formula) if Object.const_defined? :Formula

        require 'backward_compat' if backward_compat

        require 'Library/Homebrew/global'
        require 'Library/Homebrew/formula'
        require 'Library/Homebrew/os/mac'

        require 'sandbox/argv'
        require 'sandbox/coretap'
        require 'sandbox/development_tools'
        require 'sandbox/formulary'
        require 'sandbox/macos'

        Formulary.repositories = repositories

        formulae_info = {}
        formulae.each do |name|
          begin
            formula_name = File.basename name, '.rb'
            formula_class = Formula.class_s(formula_name).to_sym
            if Object.const_defined? formula_class
              Object.send :remove_const, formula_class
              $LOADED_FEATURES.reject! { |p| p =~ /\/#{formula_name}.rb/ }
            end

            if backward_compat
              formula = Formula.factory name
            else
              formula = Formulary.factory name
            end

            current_formula_info = formulae_info[formula.name] = {
              description: formula.desc,
              deps: formula.deps.map(&:to_s),
              homepage: formula.homepage,
              keg_only: !!formula.keg_only?,
              stable_version: formula.stable.try(:version).try(:to_s),
              devel_version: formula.devel.try(:version).try(:to_s),
              head_version: formula.head.try(:version).try(:to_s)
            }

            if current_formula_info[:stable_version].nil? &&
                current_formula_info[:devel_version].nil? &&
                current_formula_info[:head_version].nil?
                current_formula_info[:stable_version] = formula.version.to_s
            end
          rescue FormulaSpecificationError, FormulaUnavailableError,
                 FormulaValidationError, NoMethodError, RuntimeError,
                 SyntaxError, TypeError
            error_msg = "Formula '#{name}' could not be imported because of an error:\n" <<
                    "    #{$!.class}: #{$!.message}"
            if $DEBUG
              $!.backtrace.each { |line| error_msg << "  #{line}\n" }
            end
            Rails.logger.warn error_msg
            if defined? Airbrake
              Airbrake.notify $!, { error_message: error_msg }
            end
          end
        end

        File.binwrite tmp_file, Marshal.dump(formulae_info)
      rescue
        File.binwrite tmp_file, Marshal.dump($!)
      end
    end

    Process.wait pid
    formulae_info = Marshal.load File.binread(tmp_file)
    tmp_file.unlink
    if formulae_info.is_a? StandardError
      raise formulae_info, formulae_info.message, formulae_info.backtrace
    end

    formulae_info
  end

  def formula_regex
    return Regexp.new(special_formula_regex) unless special_formula_regex.nil?

    core? ? /^(?:Library\/)?Formula\/(.+?)\.rb$/ : /^(.+?\.rb)$/
  end

  def generate_formula_history(formula)
    Rails.logger.info "Regenerating history for formula #{formula.name}..."

    analyze_commits "--follow -- #{formula.path}"
  end

  def generate_history!
    update_status

    Rails.logger.info "Resetting history of #{name}"
    self.formulae.each { |f| f.revisions.nullify }
    self.revisions.destroy
    self.revisions.clear
    self.authors.destroy
    self.authors.clear

    generate_history
  end

  def generate_history(last_sha = nil)
    return if last_sha == sha

    ref = last_sha.nil? ? 'HEAD' : "#{last_sha}..HEAD"

    Rails.logger.info "Regenerating history for #{ref}..."

    log_cmd = ref
    log_cmd << " -- 'Formula'" if core?

    analyze_commits log_cmd
  end

  def recover_deleted_formulae
    clone_or_pull false
    reset_head

    log_cmd = "log --format=format:'%H' --diff-filter=D -M --name-only"
    log_cmd << " -- 'Formula'" if core?

    git(log_cmd).split(/\n\n/).each do |commit|
      sha, *files = commit.lines
      sha.strip!

      formulae = files.map do |path|
        next unless path =~ formula_regex
        name = File.basename $1, '.rb'
        $1 if name != '__template' && !self.formulae.where(name: name).exists?
      end.compact
      formulae.compact!

      next if formulae.empty?

      Rails.logger.debug "Trying to recover the following formulae: #{formulae.join ', '}"
      begin
        sha << '^'
        reset_head sha

        Rails.logger.debug "Trying to import missing formulae from commit #{sha}…"

        formulae_info = formulae_info formulae, true
        formulae.each do |name|
          formula_name = File.basename name, '.rb'
          formula = self.formulae.find_or_initialize_by name: formula_name
          formula_info = formulae_info.delete formula.name
          next if formula_info.nil?
          formula.deps = formula_info[:deps].map do |dep|
            self.formulae.where(name: dep).first ||
              Repository.core.formulae.where(name: dep).first
          end
          formula.removed = true
          formula.update_metadata formula_info
          formula.save
          Rails.logger.info "Successfully recovered #{formula.name} from commit #{sha}"
        end
      rescue
        error_msg = "Commit #{sha} could not be imported because of an error: #{$!.message}"
        if $DEBUG
          $!.backtrace.each { |line| error_msg << "  #{line}\n" }
        end
        Rails.logger.debug error_msg
        retry unless sha =~ /\^\^\^\^\^/
      end
    end

    reset_head
  end

  def refresh
    formulae, aliases, last_sha = update_status

    if formulae.empty? && aliases.empty?
      Rails.logger.info 'No formulae changed.'
      touch
      save!
      return last_sha
    end

    formulae_info = formulae_info formulae.map { |type, fpath|
      fpath.match(formula_regex)[1] unless type == 'D'
    }.compact

    added = modified = removed = 0
    formulae.each do |type, fpath|
      path, name = File.split fpath.match(formula_regex)[1]
      name = File.basename name, '.rb'
      formula = self.formulae.find_or_initialize_by name: name
      formula.path = (core? || path == '.' ? nil : path)
      if type == 'D'
        removed += 1
        formula.removed = true
        Rails.logger.debug "Removed formula #{formula.name}."
      else
        if type == 'A'
          added += 1
          Rails.logger.debug "Added formula #{formula.name}."
        else
          modified += 1
          Rails.logger.debug "Updated formula #{formula.name}."
        end
        formula_info = formulae_info.delete formula.name
        next if formula_info.nil?
        formula.deps = formula_info[:deps].map do |dep|
          self.formulae.where(name: dep).first ||
            Repository.core.formulae.where(name: dep).first
        end
        formula.update_metadata formula_info
        formula.removed = false
      end
      formula.save!
    end

    aliases.each do |type, apath|
      name = apath.match(ALIAS_REGEX)[1]
      if type == 'D'
        formula = self.formulae.where(aliases: name).first
        next if formula.nil?
        formula.aliases.delete name
      else
        alias_path = File.join path, apath
        next unless FileTest.symlink? alias_path
        formula_name  = File.basename File.readlink(alias_path), '.rb'
        formula = self.formulae.where(name: formula_name).first
        next if formula.nil?
        formula.aliases ||= []
        formula.aliases << name
      end
      formula.save!
    end

    Rails.logger.info "#{added} formulae added, #{modified} formulae modified, #{removed} formulae removed."

    self.letters = ('a'..'z').select do |letter|
      self.formulae.letter(letter).where(removed: false).exists?
    end

    last_sha
  end

  def regenerate!
    FileUtils.rm_rf path
    Formula.delete_all repository_id: id
    Revision.delete_all repository_id: id

    Formula.each do |formula|
      formula.update_attribute :dep_ids, formula.dep_ids.reject! { |i| i.starts_with? "#{id}/" }
      formula.update_attribute :revdep_ids, formula.revdep_ids.reject! { |i| i.starts_with? "#{id}/" }
    end

    authors.clear
    formulae.clear
    revisions.clear
    self.sha = nil
    save!

    refresh
    recover_deleted_formulae
    generate_history
  end

  def update_metadata
    clone_or_pull false
    reset_head

    formulae = self.formulae.where(removed: false).map do |formula|
      core? ? formula.name : formula.path
    end

    formulae_info(formulae).each do |name, formula_info|
      formula = self.formulae.find_by name: name
      formula.update_metadata formula_info
      formula.save!
    end
  end

  def update_status
    last_sha = super

    return [], [], sha if sha == last_sha

    if last_sha.nil?
      if core?
        formulae = git 'ls-tree --name-only HEAD Formula/'
        formulae = formulae.lines.map { |file| ['A', file.strip] }

        aliases = git 'ls-tree --name-only HEAD Aliases/'
        aliases = aliases.lines.map { |file| ['A', file.strip] }
      else
        formulae = git 'ls-tree --name-only -r HEAD'
        formulae = formulae.lines.select { |file| file.match formula_regex }.
          map { |file| ['A', file.strip] }

        aliases = []
      end
    else
      diff = git "diff --name-status #{last_sha}..HEAD"
      diff = diff.lines.map { |file| file.split }

      formulae = diff.select { |file| file[1] =~ formula_regex }
      aliases = core? ? diff.select { |file| file[1] =~ ALIAS_REGEX } : []
    end

    unless core?
      formulae_path = File.join repo.path, 'Formula'
      Dir.glob File.join(path, '*.rb') do |formula|
        system('ln', '-s', formula, formulae_path, err: '/dev/null')
      end
    end

    return formulae, aliases, last_sha
  end

end
