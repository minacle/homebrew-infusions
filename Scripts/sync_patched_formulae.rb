# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "rubygems"
require "set"
require "shellwords"
require "tmpdir"

Rule = Struct.new(:formula, :patch_path, :range_text, :requirement, keyword_init: true)
DesiredFormula = Struct.new(:formula, :version, :patch_path, :source_relpath, :output_relpath, :content, keyword_init: true)
ChangeSet = Struct.new(:formula, :type, :version, :write_relpath, :write_content, :delete_relpaths, keyword_init: true)

class PatchApplyError < StandardError; end

def abort_with(message)
  warn(message)
  exit(1)
end

def run_git!(*args, chdir:)
  stdout, stderr, status = Open3.capture3("git", *args, chdir: chdir)
  return stdout if status.success?

  abort_with <<~ERROR
    Command failed: #{(["git"] + args).shelljoin}
    #{stderr}
  ERROR
end

def capture_git(*args, chdir:)
  Open3.capture3("git", *args, chdir: chdir)
end

def filters_from(value)
  return [] if value.nil? || value.strip.empty?

  value.split(",").map(&:strip).reject(&:empty?).uniq.sort
end

def current_formula_relpath(formula)
  "Formula/#{formula[0]}/#{formula}.rb"
end

def legacy_formula_relpath(formula)
  "Formula/#{formula}.rb"
end

def upstream_candidate_relpaths(formula)
  [current_formula_relpath(formula), legacy_formula_relpath(formula)].uniq
end

def output_formula_relpath(formula)
  current_formula_relpath(formula)
end

def normalize_requirement_token(token)
  stripped = token.strip
  stripped.sub(/\A(~>|>=|<=|=|>|<)\s*/, '\1 ')
end

def parse_requirement(range_text, patch_path)
  tokens = range_text.split(",").map { |token| normalize_requirement_token(token) }.reject(&:empty?)
  abort_with("Patch range is empty: #{patch_path}") if tokens.empty?

  Gem::Requirement.new(*tokens)
rescue Gem::Requirement::BadRequirementError => e
  abort_with("Invalid version requirement in #{patch_path}: #{e.message}")
end

def patch_rules(patches_root, filters)
  patches_dir = Pathname(patches_root).join("Patches")
  formulas =
    if filters.any?
      filters
    elsif patches_dir.directory?
      patches_dir.children.select(&:directory?).map { |path| path.basename.to_s }.sort
    else
      []
    end

  formulas.to_h do |formula|
    dir = patches_dir.join(formula)
    patches = dir.directory? ? dir.children.select { |path| path.file? && path.basename.to_s.end_with?(".patch") }.sort : []
    rules = patches.map do |patch_path|
      range_text = patch_path.basename.to_s.delete_suffix(".patch")
      Rule.new(
        formula: formula,
        patch_path: patch_path,
        range_text: range_text,
        requirement: parse_requirement(range_text, patch_path)
      )
    end

    [formula, rules]
  end
end

def upstream_formula_path(upstream_root, formula)
  upstream_candidate_relpaths(formula)
    .map { |relpath| Pathname(upstream_root).join(relpath) }
    .find(&:file?)
end

def explicit_formula_version(path)
  contents = path.read
  match = contents.match(/^\s*version\s+["']([^"']+)["']/)
  return match[1] if match

  url_match = contents.match(/^\s*url\s+["'][^"']*?([0-9][0-9A-Za-z._+-]*)\.(?:tar\.gz|tgz|tar\.bz2|tbz2|tar\.xz|txz|zip)["']/)
  url_match&.[](1)
end

def homebrew_formula_version(path)
  @homebrew_loaded =
    if defined?(@homebrew_loaded)
      @homebrew_loaded
    else
      begin
        require "formula"
        require "formulary"
        true
      rescue LoadError
        false
      end
    end

  return nil unless @homebrew_loaded && defined?(Formulary)

  Formulary.factory(Pathname(path.to_s)).version.to_s
rescue StandardError => e
  warn("Warning: Homebrew could not read #{path}: #{e.class}: #{e.message}")
  nil
end

def formula_version(path)
  version = explicit_formula_version(path) || homebrew_formula_version(path)
  abort_with("Unable to determine upstream formula version for #{path}") if version.nil? || version.empty?

  version
end

def gem_version(version, path)
  Gem::Version.new(version)
rescue ArgumentError => e
  abort_with("Version #{version.inspect} from #{path} cannot be compared with Gem::Requirement: #{e.message}")
end

def apply_patch_attempt(upstream_path, patch_path, candidate_relpath, apply_args)
  Dir.mktmpdir("sync-patched-formulae-") do |dir|
    root = Pathname(dir)
    candidate = root.join(candidate_relpath)
    FileUtils.mkdir_p(candidate.dirname)
    FileUtils.cp(upstream_path, candidate)

    run_git!("init", "--quiet", chdir: dir)
    run_git!("add", "--", candidate_relpath, chdir: dir)
    run_git!(
      "-c", "user.name=sync-patched-formulae",
      "-c", "user.email=sync-patched-formulae@example.invalid",
      "-c", "commit.gpgsign=false",
      "commit", "--quiet", "-m", "base formula",
      chdir: dir
    )

    _stdout, stderr, status = capture_git("apply", "--whitespace=nowarn", *apply_args, patch_path.to_s, chdir: dir)
    raise PatchApplyError, stderr unless status.success?

    changed, _changed_stderr, changed_status = capture_git("diff", "--name-only", "HEAD", "--", chdir: dir)
    raise PatchApplyError, "could not inspect changed files" unless changed_status.success?

    changed_paths = changed.lines.map(&:strip).reject(&:empty?)
    unless changed_paths.include?(candidate_relpath)
      raise PatchApplyError, "patch did not modify #{candidate_relpath}; changed #{changed_paths.join(", ")}"
    end

    unexpected = changed_paths.reject { |path| path == candidate_relpath }
    unless unexpected.empty?
      raise PatchApplyError, "patch modifies unexpected files: #{unexpected.join(", ")}"
    end

    raise PatchApplyError, "patched formula was removed" unless candidate.file?

    return candidate.read
  end
end

def apply_patch_to_upstream(formula, upstream_path, patch_path, source_relpath)
  candidates = [source_relpath, current_formula_relpath(formula), legacy_formula_relpath(formula), "#{formula}.rb"].uniq
  failures = []

  candidates.each do |candidate_relpath|
    [["--3way"], []].each do |apply_args|
      return apply_patch_attempt(upstream_path, patch_path, candidate_relpath, apply_args)
    rescue PatchApplyError => e
      mode = apply_args.empty? ? "plain" : apply_args.join(" ")
      failures << "#{candidate_relpath} (#{mode}): #{e.message.lines.first&.strip}"
    end
  end

  abort_with <<~ERROR
    Failed to apply #{patch_path} to #{formula}.
    #{failures.map { |failure| "  - #{failure}" }.join("\n")}
  ERROR
end

def desired_formulae(repo_root, patches_root, upstream_root, filters)
  rules_by_formula = patch_rules(patches_root, filters)
  desired = {}

  rules_by_formula.each do |formula, rules|
    if rules.empty?
      warn("No patch rules found for #{formula}; no local formula will be desired.")
      next
    end

    upstream_path = upstream_formula_path(upstream_root, formula)
    unless upstream_path
      warn("No upstream formula found for #{formula}; no local formula will be desired.")
      next
    end

    version = formula_version(upstream_path)
    comparable_version = gem_version(version, upstream_path)
    matches = rules.select { |rule| rule.requirement.satisfied_by?(comparable_version) }

    if matches.empty?
      warn("No patch range for #{formula} matches upstream version #{version}; no local formula will be desired.")
      next
    end

    if matches.length > 1
      abort_with <<~ERROR
        Multiple patch ranges for #{formula} match upstream version #{version}:
        #{matches.map { |rule| "  - #{rule.patch_path} (#{rule.range_text})" }.join("\n")}
      ERROR
    end

    match = matches.fetch(0)
    source_relpath = upstream_path.relative_path_from(Pathname(upstream_root)).to_s
    output_relpath = output_formula_relpath(formula)
    content = apply_patch_to_upstream(formula, upstream_path, match.patch_path, source_relpath)

    desired[formula] = DesiredFormula.new(
      formula: formula,
      version: version,
      patch_path: match.patch_path,
      source_relpath: source_relpath,
      output_relpath: output_relpath,
      content: content
    )
  end

  desired
end

def local_formula_files(repo_root)
  root = Pathname(repo_root)
  patterns = [root.join("Formula", "*.rb").to_s, root.join("Formula", "**", "*.rb").to_s]
  patterns.flat_map { |pattern| Dir.glob(pattern) }.uniq.sort.map { |path| Pathname(path) }
end

def formula_name_from_path(path)
  path.basename.to_s.delete_suffix(".rb")
end

def build_changes(repo_root, desired, filters)
  root = Pathname(repo_root)
  scoped_formulas = filters.any? ? filters.to_set : nil
  desired_paths = desired.transform_values(&:output_relpath)
  changes = {}

  desired.each_value do |formula|
    output_path = root.join(formula.output_relpath)
    next if output_path.file? && output_path.read == formula.content

    changes[formula.formula] = ChangeSet.new(
      formula: formula.formula,
      type: output_path.file? ? :update : :add,
      version: formula.version,
      write_relpath: formula.output_relpath,
      write_content: formula.content,
      delete_relpaths: []
    )
  end

  local_formula_files(root).each do |path|
    relpath = path.relative_path_from(root).to_s
    formula = formula_name_from_path(path)
    next if scoped_formulas && !scoped_formulas.include?(formula)
    next if desired_paths[formula] == relpath

    change = changes[formula] ||= ChangeSet.new(
      formula: formula,
      type: :remove,
      version: nil,
      write_relpath: nil,
      write_content: nil,
      delete_relpaths: []
    )
    change.delete_relpaths << relpath
  end

  changes
end

def change_description(change)
  case change.type
  when :add
    "add #{change.write_relpath}"
  when :update
    "update #{change.write_relpath}"
  when :remove
    "remove #{change.delete_relpaths.join(", ")}"
  else
    change.type.to_s
  end
end

def commit_message(change)
  case change.type
  when :add
    "#{change.formula} #{change.version}: add patched formula"
  when :update
    "#{change.formula} #{change.version}: apply local patch"
  when :remove
    "#{change.formula}: remove patched formula"
  else
    abort_with("Unknown change type #{change.type} for #{change.formula}")
  end
end

def apply_changes(repo_root, changes)
  root = Pathname(repo_root)

  changes.each_value do |change|
    if change.write_relpath
      target = root.join(change.write_relpath)
      FileUtils.mkdir_p(target.dirname)
      target.write(change.write_content)
    end

    change.delete_relpaths.each do |relpath|
      FileUtils.rm_f(root.join(relpath))
    end
  end
end

def commit_changes(repo_root, changes)
  changes.values.sort_by(&:formula).each do |change|
    paths = ([change.write_relpath] + change.delete_relpaths).compact.uniq
    run_git!("add", "--all", "--", *paths, chdir: repo_root)
    _stdout, _stderr, status = capture_git("diff", "--cached", "--quiet", "--", *paths, chdir: repo_root)
    next if status.success?

    run_git!("-c", "commit.gpgsign=false", "commit", "-m", commit_message(change), chdir: repo_root)
    puts("Committed #{change.formula}: #{change_description(change)}")
  end
end

options = {
  repo_root: Dir.pwd,
  patches_root: nil,
  upstream_root: nil,
  formula: nil,
  dry_run: false,
  list_upstream_paths: false
}

OptionParser.new do |parser|
  parser.on("--repo-root PATH") { |value| options[:repo_root] = value }
  parser.on("--patches-root PATH") { |value| options[:patches_root] = value }
  parser.on("--upstream-root PATH") { |value| options[:upstream_root] = value }
  parser.on("--formula NAMES") { |value| options[:formula] = value }
  parser.on("--dry-run") { options[:dry_run] = true }
  parser.on("--list-upstream-paths") { options[:list_upstream_paths] = true }
end.parse!

abort_with("--patches-root is required") unless options[:patches_root]

filters = filters_from(options[:formula])

if options[:list_upstream_paths]
  rules = patch_rules(options[:patches_root], filters)
  paths = rules.keys.flat_map { |formula| upstream_candidate_relpaths(formula) }.uniq.sort
  puts(paths)
  exit(0)
end

abort_with("--upstream-root is required") unless options[:upstream_root]

desired = desired_formulae(options[:repo_root], options[:patches_root], options[:upstream_root], filters)
changes = build_changes(options[:repo_root], desired, filters)

if changes.empty?
  puts("No formula changes needed.")
  exit(0)
end

puts("Formula changes:")
changes.values.sort_by(&:formula).each do |change|
  puts("  - #{change.formula}: #{change_description(change)}")
end

if options[:dry_run]
  puts("Dry run enabled; no files were changed and no commits were created.")
  exit(0)
end

apply_changes(options[:repo_root], changes)
commit_changes(options[:repo_root], changes)
