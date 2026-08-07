# Changelog data source

Each crate gets a `changelog` file whose content is the URL of that
crate's changelog.

Crate names longer than two characters are sharded by their first two
letters, so `tracexec` lives at `tr/acexec/changelog`:

```text
tr/
└── acexec/
    └── changelog   <- https://github.com/kxxt/tracexec/blob/main/CHANGELOG.md
```

Names of at most two characters go directly at `<name>/changelog`.

The URL must be an `http(s)://` URL. Dot-directories (`.github`, ...)
are ignored. The generator validates everything and fails loudly on
mistakes, so a pull request with a malformed entry cannot go unnoticed.

Tip: use the helper subcommand instead of editing by hand:

```console
$ cargo run -- add <crate-name> <changelog-url>
```
