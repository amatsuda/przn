# frozen_string_literal: true

require_relative "lib/przn/version"

Gem::Specification.new do |spec|
  spec.name = "przn"
  spec.version = Przn::VERSION
  spec.authors = ["Akira Matsuda"]
  spec.email = ["ronnie@dio.jp"]

  spec.summary = 'Terminal presentation tool'
  spec.description = 'A terminal-based presentation tool that renders Markdown slides with Kitty text sizing protocol support for beautifully scaled headers'
  spec.homepage = 'https://github.com/amatsuda/przn'
  spec.license = "MIT"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "prawn"
end
