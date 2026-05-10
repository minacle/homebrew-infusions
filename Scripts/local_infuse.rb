#!/usr/bin/env ruby
# frozen_string_literal: true

require "open-uri"
require "optparse"
require "pathname"

require_relative "sync_infused_formulae"

def fetch_upstream_formula(formula, upstream_ref)
  upstream_candidate_relpaths(formula).each do |relpath|
    url = "https://raw.githubusercontent.com/Homebrew/homebrew-core/#{upstream_ref}/#{relpath}"
    begin
      return [URI.open(url, &:read), "Homebrew/homebrew-core@#{upstream_ref}:#{relpath}"]
    rescue OpenURI::HTTPError => e
      raise unless e.io.status.fetch(0) == "404"
    end
  end

  abort_with("No upstream formula found for #{formula} at Homebrew/homebrew-core@#{upstream_ref}")
end

def read_upstream_formula(formula, options)
  if options[:upstream_formula]
    path = Pathname(options[:upstream_formula])
    abort_with("Upstream formula file not found: #{path}") unless path.file?

    return [path.read, path]
  end

  if options[:upstream_root]
    path = upstream_formula_path(options[:upstream_root], formula)
    abort_with("No upstream formula found for #{formula} under #{options[:upstream_root]}") unless path

    return [path.read, path]
  end

  fetch_upstream_formula(formula, options[:upstream_ref])
end

def run_local_infuse(argv = ARGV)
  options = {
    upstream_ref: "main",
    upstream_root: nil,
    upstream_formula: nil,
    output: nil,
    force: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: brew ruby -- Scripts/local_infuse.rb INFUSION.rb [options]"
    opts.on("--upstream-root PATH", "Use a local Homebrew/homebrew-core checkout") { |value| options[:upstream_root] = value }
    opts.on("--upstream-formula PATH", "Use a specific upstream formula file") { |value| options[:upstream_formula] = value }
    opts.on("--upstream-ref REF", "Homebrew/homebrew-core ref to fetch when no local upstream is given") { |value| options[:upstream_ref] = value }
    opts.on("--output PATH", "Output path, default: ./<formula>.infused.rb") { |value| options[:output] = value }
    opts.on("--force", "Overwrite an existing explicit --output file") { options[:force] = true }
  end

  parser.parse!(argv)
  abort_with(parser.to_s) unless argv.length == 1
  abort_with("Use only one of --upstream-root and --upstream-formula") if options[:upstream_root] && options[:upstream_formula]

  infusion_path = Pathname(argv.fetch(0))
  abort_with("Infusion file not found: #{infusion_path}") unless infusion_path.file?
  abort_with("Infusion file must have a .rb extension: #{infusion_path}") unless infusion_path.basename.to_s.end_with?(".rb")

  formula = infusion_path.basename.to_s.delete_suffix(".rb")
  infusion = parse_infusion_file(infusion_path, formula)
  upstream_source, upstream_label = read_upstream_formula(formula, options)
  default_output = options[:output].nil?
  output_path = Pathname(options[:output] || File.join(Dir.pwd, "#{formula}.infused.rb"))

  if output_path.expand_path == infusion_path.expand_path
    abort_with("Refusing to overwrite the infusion file: #{infusion_path}")
  end

  if !default_output && output_path.exist? && !options[:force]
    abort_with("Output file already exists: #{output_path}. Use --force to overwrite it.")
  end

  output_path.dirname.mkpath
  output_path.write(apply_infusion_to_source(upstream_source, upstream_label, infusion))
  puts("Wrote #{output_path}")
end

run_local_infuse if $PROGRAM_NAME == __FILE__
