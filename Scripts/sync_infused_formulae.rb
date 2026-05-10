# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "ripper"
require "rubygems"
require "set"
require "shellwords"
require "tempfile"

METHOD_TARGETS = Set["install", "post_install"].freeze
BLOCK_TARGETS = Set["test", "service", "livecheck", "bottle", "head", "stable"].freeze
CONTEXT_TARGETS = Set["on_macos", "on_linux", "on_arm", "on_intel", "on_system"].freeze
DSL_BLOCK_TARGETS = BLOCK_TARGETS + CONTEXT_TARGETS
SUPPORTED_TARGETS = METHOD_TARGETS + DSL_BLOCK_TARGETS
SPACE_TYPES = Set[:on_sp, :on_ignored_nl, :on_nl, :on_comment].freeze

Token = Struct.new(:index, :line, :column, :type, :text, :state, :start_offset, :end_offset, keyword_init: true)
SourceInfo = Struct.new(:source, :path, :line_offsets, :tokens, keyword_init: true)
Selector = Struct.new(:name, :argument_source, :argument_signature, keyword_init: true)
Operation = Struct.new(:kind, :target, :context_path, :body, :path, :line, :sequence, keyword_init: true)
Infusion = Struct.new(:formula, :declared_name, :path, :operations, keyword_init: true)
SourceBlock = Struct.new(
  :kind,
  :target,
  :open_index,
  :end_index,
  :start_offset,
  :body_start,
  :body_end,
  :end_offset,
  :end_line_start,
  :end_indent,
  :body_indent,
  keyword_init: true
)
DesiredFormula = Struct.new(:formula, :version, :infusion_path, :source_relpath, :output_relpath, :content, keyword_init: true)
ChangeSet = Struct.new(:formula, :type, :version, :write_relpath, :write_content, :delete_relpaths, keyword_init: true)

def abort_with(message)
  warn(message)
  exit(1)
end

def ensure_supported_ruby!
  return if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0.0")

  abort_with("Ruby 3.0 or newer is required. Run this script with Homebrew Ruby: brew ruby -- #{$PROGRAM_NAME}")
end

ensure_supported_ruby!

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

def formula_class_name(formula)
  unless formula.match?(/\A[a-z0-9]+(?:_[a-z0-9]+)*\z/)
    abort_with("Invalid infusion filename #{formula.inspect}; expected lowercase words separated by single underscores")
  end

  formula.split("_").map { |part| part[0].upcase + part[1..-1].to_s }.join
end

def line_offsets_for(source)
  offsets = [0]
  source.each_line { |line| offsets << offsets.last + line.bytesize }
  offsets
end

def source_info(source, path)
  line_offsets = line_offsets_for(source)
  tokens = Ripper.lex(source).each_with_index.map do |((line, column), type, text, state), index|
    start_offset = line_offsets.fetch(line - 1) + column
    Token.new(
      index: index,
      line: line,
      column: column,
      type: type,
      text: text,
      state: state,
      start_offset: start_offset,
      end_offset: start_offset + text.bytesize
    )
  end

  SourceInfo.new(source: source, path: path, line_offsets: line_offsets, tokens: tokens)
end

def assert_ruby_syntax(source, path)
  return unless Ripper.sexp(source).nil?

  abort_with("Invalid Ruby syntax in #{path}")
end

def next_significant(tokens, index, limit = nil)
  i = index
  limit ||= tokens.length
  while i < limit
    return i unless SPACE_TYPES.include?(tokens.fetch(i).type)

    i += 1
  end
  nil
end

def previous_significant(tokens, index)
  i = index
  while i >= 0
    return i unless SPACE_TYPES.include?(tokens.fetch(i).type)

    i -= 1
  end
  nil
end

def line_start_offset(info, token)
  info.line_offsets.fetch(token.line - 1)
end

def line_indent_before(info, token)
  info.source[line_start_offset(info, token)...token.start_offset]
end

def statement_keyword?(tokens, index)
  token = tokens.fetch(index)
  previous_index = previous_significant(tokens, index - 1)
  return true if previous_index.nil?

  previous = tokens.fetch(previous_index)
  previous.line != token.line || [";", "then", "do"].include?(previous.text)
end

def keyword_on_same_line_before?(tokens, index, keywords)
  token = tokens.fetch(index)
  i = previous_significant(tokens, index - 1)
  while i
    previous = tokens.fetch(i)
    return false if previous.line != token.line
    return true if previous.type == :on_kw && keywords.include?(previous.text)

    i = previous_significant(tokens, i - 1)
  end
  false
end

def structural_opener?(tokens, index)
  token = tokens.fetch(index)
  return false unless token.type == :on_kw

  case token.text
  when "class", "module", "def", "begin", "case"
    true
  when "if", "unless", "while", "until", "for"
    statement_keyword?(tokens, index)
  when "do"
    !keyword_on_same_line_before?(tokens, index, %w[while until for])
  else
    false
  end
end

def matching_end_index(tokens, open_index)
  depth = 1
  i = open_index + 1
  while i < tokens.length
    token = tokens.fetch(i)
    if structural_opener?(tokens, i)
      depth += 1
    elsif token.type == :on_kw && token.text == "end"
      depth -= 1
      return i if depth.zero?
    end
    i += 1
  end

  abort_with("Could not find matching end for #{tokens.fetch(open_index).text} at line #{tokens.fetch(open_index).line}")
end

def find_do_index(tokens, index, limit = nil)
  limit ||= tokens.length
  i = index + 1
  while i < limit
    token = tokens.fetch(i)
    return nil if [:on_nl, :on_ignored_nl].include?(token.type)
    return i if token.type == :on_kw && token.text == "do"

    i += 1
  end
  nil
end

def body_start_after_do(info, do_index, end_index)
  tokens = info.tokens
  offset = tokens.fetch(do_index).end_offset
  i = do_index + 1

  first = next_significant(tokens, i, end_index)
  if first && tokens.fetch(first).type == :on_op && tokens.fetch(first).text == "|"
    close = first + 1
    close += 1 until close >= end_index || (tokens.fetch(close).type == :on_op && tokens.fetch(close).text == "|")
    abort_with("Unterminated block parameters in #{info.path}:#{tokens.fetch(do_index).line}") if close >= end_index

    offset = tokens.fetch(close).end_offset
    i = close + 1
  end

  while i < end_index && [:on_sp, :on_ignored_nl, :on_nl].include?(tokens.fetch(i).type)
    offset = tokens.fetch(i).end_offset
    break if [:on_ignored_nl, :on_nl].include?(tokens.fetch(i).type)

    i += 1
  end

  offset
end

def literal_string_between(info, start_index, end_index)
  tokens = info.tokens
  i = start_index
  while i < end_index
    if tokens.fetch(i).type == :on_tstring_beg
      pieces = []
      i += 1
      while i < end_index && tokens.fetch(i).type != :on_tstring_end
        token = tokens.fetch(i)
        abort_with("Interpolated infusion names are not supported in #{info.path}:#{token.line}") if token.type == :on_embexpr_beg

        pieces << token.text if token.type == :on_tstring_content
        i += 1
      end
      abort_with("Unterminated string in #{info.path}") if i >= end_index

      return pieces.join
    end
    i += 1
  end
  nil
end

def symbol_argument_after(info, index, limit)
  tokens = info.tokens
  sym_index = next_significant(tokens, index + 1, limit)
  token = sym_index && tokens.fetch(sym_index)
  unless token&.type == :on_symbeg && token.text == ":"
    abort_with("Expected symbol target in #{info.path}:#{tokens.fetch(index).line}")
  end

  name_index = next_significant(tokens, sym_index + 1, limit)
  name = name_index && tokens.fetch(name_index)
  unless name&.type == :on_ident
    abort_with("Expected symbol target name in #{info.path}:#{token.line}")
  end

  [name.text, name_index]
end

def selector_arguments_between(info, name_index, do_index)
  tokens = info.tokens
  argument_source = info.source[tokens.fetch(name_index).end_offset...tokens.fetch(do_index).start_offset].strip
  argument_signature = tokens[(name_index + 1)...do_index]
                       .reject { |token| SPACE_TYPES.include?(token.type) }
                       .map(&:text)
                       .join("\0")

  [argument_source, argument_signature]
end

def selector_from_call(info, name_index, do_index)
  argument_source, argument_signature = selector_arguments_between(info, name_index, do_index)
  Selector.new(
    name: info.tokens.fetch(name_index).text,
    argument_source: argument_source,
    argument_signature: argument_signature
  )
end

def selector_key(selector)
  [selector.name, selector.argument_signature]
end

def selector_path_key(selectors)
  selectors.map { |selector| selector_key(selector) }
end

def selector_source(selector)
  selector.argument_source.empty? ? selector.name : "#{selector.name} #{selector.argument_source}"
end

def selector_display(selector)
  selector.argument_source.empty? ? selector.name : "#{selector.name} #{selector.argument_source}"
end

def target_selector(target)
  Selector.new(name: target, argument_source: "", argument_signature: "")
end

def normalize_body(raw_body)
  lines = raw_body.lines
  lines.shift while lines.any? && lines.first.strip.empty?
  lines.pop while lines.any? && lines.last.strip.empty?
  return "" if lines.empty?

  indent = lines.reject { |line| line.strip.empty? }
                .map { |line| line[/\A[ \t]*/].bytesize }
                .min || 0
  lines.map { |line| line.sub(/\A[ \t]{0,#{indent}}/, "") }.join.chomp
end

def indent_body(body, body_indent, end_indent)
  return end_indent if body.empty?

  body.split("\n", -1).map do |line|
    line.empty? ? "\n" : "#{body_indent}#{line}\n"
  end.join + end_indent
end

def parse_infusion_entries(info, start_index, end_index, context_path, operations)
  tokens = info.tokens
  i = start_index

  while i < end_index
    significant = next_significant(tokens, i, end_index)
    break if significant.nil?

    token = tokens.fetch(significant)
    unless token.type == :on_ident
      abort_with("Unknown infusion DSL entry in #{info.path}:#{token.line}: #{token.text.inspect}")
    end

    if %w[before after overwrite].include?(token.text)
      target, target_index = symbol_argument_after(info, significant, end_index)
      abort_with("Unsupported infusion target :#{target} in #{info.path}:#{token.line}") unless SUPPORTED_TARGETS.include?(target)
      if context_path.any? && METHOD_TARGETS.include?(target)
        abort_with("Method target :#{target} is only supported at the formula class level in #{info.path}:#{token.line}")
      end

      do_index = find_do_index(tokens, target_index, end_index)
      abort_with("Expected do block for #{token.text} :#{target} in #{info.path}:#{token.line}") unless do_index

      extra_index = next_significant(tokens, target_index + 1, do_index)
      if extra_index
        abort_with("Additional operation target arguments are not supported in #{info.path}:#{tokens.fetch(extra_index).line}")
      end

      operation_end_index = matching_end_index(tokens, do_index)
      if operation_end_index > end_index
        abort_with("Operation #{token.text} :#{target} escapes infusion block in #{info.path}:#{token.line}")
      end

      body_start = body_start_after_do(info, do_index, operation_end_index)
      body = normalize_body(info.source[body_start...tokens.fetch(operation_end_index).start_offset])
      operations << Operation.new(
        kind: token.text,
        target: target,
        context_path: context_path.dup,
        body: body,
        path: info.path,
        line: token.line,
        sequence: operations.length
      )
      i = operation_end_index + 1
      next
    end

    unless CONTEXT_TARGETS.include?(token.text)
      abort_with("Unknown infusion DSL entry in #{info.path}:#{token.line}: #{token.text.inspect}")
    end

    do_index = find_do_index(tokens, significant, end_index)
    abort_with("Expected do block for context #{token.text} in #{info.path}:#{token.line}") unless do_index

    context_end_index = matching_end_index(tokens, do_index)
    abort_with("Context #{token.text} escapes infusion block in #{info.path}:#{token.line}") if context_end_index > end_index

    selector = selector_from_call(info, significant, do_index)
    parse_infusion_entries(info, do_index + 1, context_end_index, context_path + [selector], operations)
    i = context_end_index + 1
  end
end

def parse_operations(info, infusion_do_index, infusion_end_index)
  operations = []
  parse_infusion_entries(info, infusion_do_index + 1, infusion_end_index, [], operations)
  operations
end

def parse_infusion_file(path, formula)
  source = path.read
  assert_ruby_syntax(source, path)
  info = source_info(source, path)
  tokens = info.tokens

  infusion_indexes = tokens.each_index.select { |index| tokens.fetch(index).type == :on_ident && tokens.fetch(index).text == "infusion" }
  abort_with("No infusion declaration found in #{path}") if infusion_indexes.empty?
  abort_with("Multiple infusion declarations found in #{path}") if infusion_indexes.length > 1

  infusion_index = infusion_indexes.fetch(0)
  do_index = find_do_index(tokens, infusion_index)
  abort_with("Expected do block for infusion declaration in #{path}:#{tokens.fetch(infusion_index).line}") unless do_index

  declared_name = literal_string_between(info, infusion_index + 1, do_index)
  abort_with("Expected infusion name string in #{path}:#{tokens.fetch(infusion_index).line}") unless declared_name

  expected_name = formula_class_name(formula)
  unless declared_name == expected_name
    abort_with("Infusion name mismatch in #{path}: expected #{expected_name.inspect}, got #{declared_name.inspect}")
  end

  end_index = matching_end_index(tokens, do_index)
  operations = parse_operations(info, do_index, end_index)
  abort_with("No operations found in #{path}") if operations.empty?

  Infusion.new(formula: formula, declared_name: declared_name, path: path, operations: operations)
end

def infusions_dir(infusions_root)
  Pathname(infusions_root).join("Infusions")
end

def infusion_files(infusions_root, filters)
  dir = infusions_dir(infusions_root)
  if filters.any?
    return filters.map { |formula| dir.join("#{formula}.rb") }.select do |path|
      unless path.file?
        warn("No infusion found for #{path.basename.to_s.delete_suffix(".rb")}; no local formula will be desired.")
        false
      else
        true
      end
    end
  end

  abort_with("Infusions directory not found: #{dir}") unless dir.directory?

  files = dir.children.select { |path| path.file? && path.basename.to_s.end_with?(".rb") }.sort
  abort_with("No infusion files found in #{dir}; refusing to sync an empty infusion set.") if files.empty?

  files
end

def infusions(infusions_root, filters)
  infusion_files(infusions_root, filters).to_h do |path|
    formula = path.basename.to_s.delete_suffix(".rb")
    [formula, parse_infusion_file(path, formula)]
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
  explicit_formula_version(path) || homebrew_formula_version(path) || "unknown"
end

def target_kind(target)
  return :method if METHOD_TARGETS.include?(target)
  return :block if DSL_BLOCK_TARGETS.include?(target)

  abort_with("Unsupported infusion target :#{target}")
end

def structural_stack_before(tokens, index)
  stack = []
  i = 0
  while i < index
    token = tokens.fetch(i)
    if structural_opener?(tokens, i)
      stack << i
    elsif token.type == :on_kw && token.text == "end"
      stack.pop
    end
    i += 1
  end
  stack
end

def direct_child_token?(info, parent, index)
  token = info.tokens.fetch(index)
  token.start_offset >= parent.body_start &&
    token.start_offset < parent.body_end &&
    structural_stack_before(info.tokens, index).last == parent.open_index
end

def find_direct_child_method_block(info, parent, target)
  tokens = info.tokens
  matches = []

  tokens.each_with_index do |token, index|
    next unless token.type == :on_kw && token.text == "def"
    next unless direct_child_token?(info, parent, index)

    name_index = next_significant(tokens, index + 1)
    name = name_index && tokens.fetch(name_index)
    next unless name&.type == :on_ident && name.text == target

    end_index = matching_end_index(tokens, index)
    end_token = tokens.fetch(end_index)
    body_start = info.line_offsets.fetch(token.line)
    end_indent = line_indent_before(info, end_token)
    matches << SourceBlock.new(
      kind: :method,
      target: target,
      open_index: index,
      end_index: end_index,
      start_offset: line_start_offset(info, token),
      body_start: body_start,
      body_end: end_token.start_offset,
      end_offset: end_token.end_offset,
      end_line_start: line_start_offset(info, end_token),
      end_indent: end_indent,
      body_indent: "#{end_indent}  "
    )
  end

  if matches.length > 1
    abort_with("Multiple direct child def #{target} blocks found in #{info.path}; infusion target is ambiguous.")
  end

  matches.fetch(0, nil)
end

def find_direct_child_dsl_block(info, parent, selector)
  tokens = info.tokens
  matches = []

  tokens.each_with_index do |token, index|
    next unless token.type == :on_ident && token.text == selector.name
    next unless direct_child_token?(info, parent, index)

    previous_index = previous_significant(tokens, index - 1)
    next if previous_index && tokens.fetch(previous_index).type == :on_period

    do_index = find_do_index(tokens, index)
    next unless do_index

    next unless selector_key(selector_from_call(info, index, do_index)) == selector_key(selector)

    end_index = matching_end_index(tokens, do_index)
    next if tokens.fetch(end_index).start_offset > parent.body_end

    end_token = tokens.fetch(end_index)
    end_indent = line_indent_before(info, end_token)
    matches << SourceBlock.new(
      kind: :block,
      target: selector.name,
      open_index: do_index,
      end_index: end_index,
      start_offset: line_start_offset(info, token),
      body_start: body_start_after_do(info, do_index, end_index),
      body_end: end_token.start_offset,
      end_offset: end_token.end_offset,
      end_line_start: line_start_offset(info, end_token),
      end_indent: end_indent,
      body_indent: "#{end_indent}  "
    )
  end

  if matches.length > 1
    abort_with("Multiple direct child #{selector_display(selector)} blocks found in #{info.path}; infusion target is ambiguous.")
  end

  matches.fetch(0, nil)
end

def find_source_block(info, parent, target)
  case target_kind(target)
  when :method
    abort_with("Method target :#{target} is only supported at the formula class level") unless parent.kind == :class

    find_direct_child_method_block(info, parent, target)
  when :block
    find_direct_child_dsl_block(info, parent, target_selector(target))
  end
end

def find_formula_class_block(info)
  tokens = info.tokens
  class_index = tokens.each_index.find { |index| tokens.fetch(index).type == :on_kw && tokens.fetch(index).text == "class" }
  abort_with("No formula class found in #{info.path}") unless class_index

  end_index = matching_end_index(tokens, class_index)
  end_token = tokens.fetch(end_index)
  SourceBlock.new(
    kind: :class,
    target: "class",
    open_index: class_index,
    end_index: end_index,
    start_offset: line_start_offset(info, tokens.fetch(class_index)),
    body_start: info.line_offsets.fetch(tokens.fetch(class_index).line),
    body_end: end_token.start_offset,
    end_offset: end_token.end_offset,
    end_line_start: line_start_offset(info, end_token),
    end_indent: line_indent_before(info, end_token),
    body_indent: "#{line_indent_before(info, end_token)}  "
  )
end

def line_prefix_at(source, offset)
  line_start = source.rindex("\n", offset - 1) || -1
  source[(line_start + 1)...offset] || ""
end

def line_suffix_at(source, offset)
  line_end = source.index("\n", offset) || source.bytesize
  source[offset...line_end] || ""
end

def expand_original_calls(body, original_body, operation)
  info = source_info(body, "#{operation.path}:#{operation.line}")
  tokens = info.tokens
  edits = []
  i = 0

  while i < tokens.length
    token = tokens.fetch(i)
    if token.type == :on_ident && token.text == "original"
      period_index = next_significant(tokens, i + 1)
      call_index = period_index && next_significant(tokens, period_index + 1)
      if period_index && call_index &&
         tokens.fetch(period_index).type == :on_period &&
         tokens.fetch(call_index).type == :on_ident &&
         tokens.fetch(call_index).text == "call"
        prefix = line_prefix_at(body, token.start_offset)
        suffix = line_suffix_at(body, tokens.fetch(call_index).end_offset)
        unless prefix.strip.empty? && suffix.strip.empty?
          abort_with("original.call must be the only expression on its line in #{operation.path}:#{operation.line}")
        end

        if original_body.empty?
          line_end = body.index("\n", tokens.fetch(call_index).end_offset)
          edit_end = line_end ? line_end + 1 : body.bytesize
          edits << [line_start_offset(info, token), edit_end, ""]
        else
          replacement = original_body.split("\n", -1).join("\n#{prefix}")
          edits << [token.start_offset, tokens.fetch(call_index).end_offset, replacement]
        end
        i = call_index + 1
        next
      end
    end
    i += 1
  end

  expanded = body.dup
  edits.reverse_each do |start_offset, end_offset, replacement|
    expanded[start_offset...end_offset] = replacement
  end
  normalize_body(expanded)
end

def composed_body(original_body, operations)
  overwrites = operations.select { |operation| operation.kind == "overwrite" }
  if overwrites.length > 1
    duplicate = overwrites.fetch(1)
    abort_with("Multiple overwrite operations for :#{duplicate.target} in #{duplicate.path}:#{duplicate.line}")
  end

  base =
    if overwrites.any?
      expand_original_calls(overwrites.fetch(0).body, original_body, overwrites.fetch(0))
    else
      original_body
    end

  before = operations.select { |operation| operation.kind == "before" }.map(&:body)
  after = operations.select { |operation| operation.kind == "after" }.map(&:body)
  (before + [base] + after).reject(&:empty?).join("\n")
end

def new_target_block(kind, target, body, member_indent)
  body_indent = "#{member_indent}  "
  case kind
  when :method
    "\n#{member_indent}def #{target}\n#{indent_body(body, body_indent, member_indent)}end\n"
  when :block
    "\n#{member_indent}#{target} do\n#{indent_body(body, body_indent, member_indent)}end\n"
  else
    abort_with("Cannot create target of kind #{kind}")
  end
end

def new_context_block(selector, child_blocks, member_indent)
  "\n#{member_indent}#{selector_source(selector)} do\n#{child_blocks.sub(/\A\n/, "")}#{member_indent}end\n"
end

def first_sequence(operation_groups)
  operation_groups.flatten.map(&:sequence).min
end

def grouped_operation_sets(operations)
  operations.group_by { |operation| [selector_path_key(operation.context_path), operation.target] }.values
end

def child_operation_entries(operation_groups, depth)
  leaf_entries = operation_groups.select { |operations| operations.fetch(0).context_path.length == depth }
                                  .map { |operations| [:leaf, operations] }

  context_entries = operation_groups.reject { |operations| operations.fetch(0).context_path.length == depth }
                                    .group_by { |operations| selector_key(operations.fetch(0).context_path.fetch(depth)) }
                                    .values
                                    .map do |groups|
                                      selector = groups.fetch(0).fetch(0).context_path.fetch(depth)
                                      [:context, selector, groups]
                                    end

  (leaf_entries + context_entries).sort_by do |entry|
    entry.fetch(0) == :leaf ? first_sequence([entry.fetch(1)]) : first_sequence(entry.fetch(2))
  end
end

def render_missing_children(operation_groups, depth, member_indent)
  child_operation_entries(operation_groups, depth).map do |entry|
    if entry.fetch(0) == :leaf
      operations = entry.fetch(1)
      target = operations.fetch(0).target
      kind = target_kind(target)
      body = composed_body("", operations)
      new_target_block(kind, target, body, member_indent)
    else
      selector = entry.fetch(1)
      groups = entry.fetch(2)
      child_blocks = render_missing_children(groups, depth + 1, "#{member_indent}  ")
      new_context_block(selector, child_blocks, member_indent)
    end
  end.join
end

def collect_infusion_edits(info, parent, operation_groups, depth, edits, insertions)
  child_operation_entries(operation_groups, depth).each do |entry|
    if entry.fetch(0) == :leaf
      operations = entry.fetch(1)
      target = operations.fetch(0).target
      kind = target_kind(target)
      block = find_source_block(info, parent, target)
      original_body = block ? normalize_body(info.source[block.body_start...block.body_end]) : ""
      body = composed_body(original_body, operations)

      if block
        edits << [block.body_start, block.body_end, indent_body(body, block.body_indent, block.end_indent)]
      else
        insertions[parent.end_line_start] << new_target_block(kind, target, body, parent.body_indent)
      end
    else
      selector = entry.fetch(1)
      groups = entry.fetch(2)
      block = find_direct_child_dsl_block(info, parent, selector)

      if block
        collect_infusion_edits(info, block, groups, depth + 1, edits, insertions)
      else
        child_blocks = render_missing_children(groups, depth + 1, "#{parent.body_indent}  ")
        insertions[parent.end_line_start] << new_context_block(selector, child_blocks, parent.body_indent)
      end
    end
  end
end

def assert_non_overlapping_edits(edits)
  ranged_edits = edits.select { |start_offset, end_offset, _content| start_offset != end_offset }
                      .sort_by { |start_offset, end_offset, _content| [start_offset, end_offset] }
  insertion_edits = edits.select { |start_offset, end_offset, _content| start_offset == end_offset }

  ranged_edits.each_cons(2) do |left, right|
    next if left.fetch(1) <= right.fetch(0)

    abort_with("Conflicting infusion operations modify overlapping source ranges.")
  end

  insertion_edits.each do |insert|
    if ranged_edits.any? { |range| insert.fetch(0) > range.fetch(0) && insert.fetch(0) < range.fetch(1) }
      abort_with("Conflicting infusion operations modify both a source block and one of its descendants.")
    end
  end
end

def apply_infusion_to_source(source, upstream_path, infusion)
  info = source_info(source, upstream_path)
  formula_class = find_formula_class_block(info)
  edits = []
  insertions = Hash.new { |hash, key| hash[key] = [] }

  collect_infusion_edits(info, formula_class, grouped_operation_sets(infusion.operations), 0, edits, insertions)
  insertions.each do |offset, blocks|
    edits << [offset, offset, blocks.join]
  end
  assert_non_overlapping_edits(edits)

  updated = source.dup
  edits.sort_by { |start_offset, end_offset, _content| [start_offset, end_offset] }.reverse_each do |start_offset, end_offset, content|
    updated[start_offset...end_offset] = content
  end

  validate_generated_formula(source, updated, upstream_path, infusion.path)
  updated
end

def brew_command
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "brew") }
     .concat(%w[/opt/homebrew/bin/brew /usr/local/bin/brew])
     .find { |path| File.executable?(path) }
end

def ruby_syntax_checker
  @ruby_syntax_checker ||= begin
    brew = brew_command
    brew ? [brew, "ruby", "--", "-c"] : ["ruby", "-c"]
  end
end

def ruby_syntax_checker_name
  ruby_syntax_checker.join(" ")
end

def ruby_syntax_error(source)
  Tempfile.create(["infused-formula", ".rb"]) do |file|
    file.write(source)
    file.close
    env = { "HOMEBREW_NO_AUTO_UPDATE" => "1" }
    _stdout, stderr, status = Open3.capture3(env, *ruby_syntax_checker, file.path)
    status.success? ? nil : stderr
  end
end

def validate_generated_formula(original_source, updated_source, upstream_path, infusion_path)
  original_error = ruby_syntax_error(original_source)
  if original_error
    warn("Warning: Skipping generated formula syntax check because #{upstream_path} is not parseable by #{ruby_syntax_checker_name}.")
    return
  end

  updated_error = ruby_syntax_error(updated_source)
  return unless updated_error

  abort_with <<~ERROR
    Generated formula from #{infusion_path} and #{upstream_path} is not valid Ruby.
    #{updated_error}
  ERROR
end

def desired_formulae(infusions_root, upstream_root, filters)
  desired = {}

  infusions(infusions_root, filters).each do |formula, infusion|
    upstream_path = upstream_formula_path(upstream_root, formula)
    unless upstream_path
      warn("No upstream formula found for #{formula}; no local formula will be desired.")
      next
    end

    version = formula_version(upstream_path)
    source_relpath = upstream_path.relative_path_from(Pathname(upstream_root)).to_s
    content = apply_infusion_to_source(upstream_path.read, upstream_path, infusion)

    desired[formula] = DesiredFormula.new(
      formula: formula,
      version: version,
      infusion_path: infusion.path,
      source_relpath: source_relpath,
      output_relpath: output_formula_relpath(formula),
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
    "#{change.formula} #{change.version}: add infused formula"
  when :update
    "#{change.formula} #{change.version}: apply local infusion"
  when :remove
    "#{change.formula}: remove infused formula"
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

def run_sync_infused_formulae(argv = ARGV)
  options = {
    repo_root: Dir.pwd,
    infusions_root: nil,
    upstream_root: nil,
    formula: nil,
    dry_run: false,
    list_upstream_paths: false
  }

  OptionParser.new do |parser|
    parser.on("--repo-root PATH") { |value| options[:repo_root] = value }
    parser.on("--infusions-root PATH") { |value| options[:infusions_root] = value }
    parser.on("--upstream-root PATH") { |value| options[:upstream_root] = value }
    parser.on("--formula NAMES") { |value| options[:formula] = value }
    parser.on("--dry-run") { options[:dry_run] = true }
    parser.on("--list-upstream-paths") { options[:list_upstream_paths] = true }
  end.parse!(argv)

  abort_with("--infusions-root is required") unless options[:infusions_root]

  filters = filters_from(options[:formula])

  if options[:list_upstream_paths]
    paths = infusions(options[:infusions_root], filters).keys.flat_map { |formula| upstream_candidate_relpaths(formula) }.uniq.sort
    puts(paths)
    return
  end

  abort_with("--upstream-root is required") unless options[:upstream_root]

  desired = desired_formulae(options[:infusions_root], options[:upstream_root], filters)
  changes = build_changes(options[:repo_root], desired, filters)

  if changes.empty?
    puts("No formula changes needed.")
    return
  end

  puts("Formula changes:")
  changes.values.sort_by(&:formula).each do |change|
    puts("  - #{change.formula}: #{change_description(change)}")
  end

  if options[:dry_run]
    puts("Dry run enabled; no files were changed and no commits were created.")
    return
  end

  apply_changes(options[:repo_root], changes)
  commit_changes(options[:repo_root], changes)
end

run_sync_infused_formulae if $PROGRAM_NAME == __FILE__
