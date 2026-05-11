# Minacle Infusions

## How do I install these formulae?

`brew install minacle/infusions/<formula>`

Or `brew tap minacle/infusions` and then `brew install <formula>`.

Or, in a `brew bundle` `Brewfile`:

```ruby
tap "minacle/infusions"
brew "<formula>"
```

## Documentation

`brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).

## Infusions

Generated formulae are synchronized from `Infusions/*.rb` in this branch. The
filename determines the formula token, such as
`foo.rb` for `Foo` or `foo_bar.rb` for `FooBar`.

```ruby
infusion "Foo" do
  before :install do
    # Prepended to def install.
  end

  overwrite :service do |original|
    # Replaces service do; original.call expands the previous body.
    working_dir var
    original.call
    environment_variables FOO_EXAMPLE: "1"
  end

  overwrite :bottle
  # Removes the existing bottle block if upstream has one.

  after :test do
    # Appended to test do.
  end
end
```

Supported targets are `install`, `post_install`, `test`, `service`,
`livecheck`, `bottle`, `head`, `stable`, `on_macos`, `on_linux`, `on_arm`,
`on_intel`, and `on_system`. Missing targets are created, except for blockless
`overwrite :target`, which is a no-op when the target is absent. Each infusion
applies to the current upstream formula with the same filename token.

Nested Homebrew blocks can be used as context selectors. Operations inside a
context target only the matching direct child block at that path.

```ruby
infusion "Foo" do
  on_macos do
    after :on_arm do
      # Appended to the on_arm do block directly inside on_macos do.
    end

    overwrite :on_intel do |original|
      # Replaces only the matching nested on_intel do block.
      depends_on "foo"
      original.call
      depends_on "bar"
    end
  end

  on_system macos: :sonoma do
    after :on_arm do
      # Parameterized contexts match by their arguments.
    end
  end
end
```

If multiple direct child context blocks have the same selector, the infusion is
ambiguous and the sync fails.

To test one infusion locally without checking out or switching branches, run:

```sh
brew ruby -- Scripts/local_infuse.rb path/to/foo.rb
```

The scripts target Ruby 3.0 or newer; use Homebrew Ruby for local runs.

By default this downloads the matching upstream formula from
`Homebrew/homebrew-core` and writes or replaces `./foo.infused.rb`. Use
`--upstream-root PATH` for a local `homebrew-core` checkout,
`--upstream-formula PATH` for a specific upstream formula file, and
`--output PATH` to choose another output file. Existing explicit `--output`
files require `--force`.
