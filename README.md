# zundo.yazi

Restore files deleted from Yazi, using the freedesktop trash. It lists the
trash entries from the current batch and puts them back. It never overwrites
an existing directory wholesale: conflicts are shown for approval, and a
non-directory blocking a directory is reported as blocked.

## Requirements

- Yazi 26.9.1 or newer (uses the `fs.trash` API)
- `grep` and coreutils
- [zeppelin.yazi](https://github.com/ibtrujillo/zeppelin.yazi)

## Installation

```sh
ya pkg add ibtrujillo/zundo
ya pkg add ibtrujillo/zeppelin
```

## Usage

```lua
-- keymap.toml
[mgr]
prepend_keymap = [
  { on = ["u"], run = "plugin zundo", desc = "Restore last deleted" },
]
```

## Tests

`test.lua` loads `zeppelin.yazi` from the sibling directory, so clone both
into the same parent folder before running it:

```sh
lua test.lua
```
