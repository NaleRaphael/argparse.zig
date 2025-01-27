# argparse.zig
A simple CLI argument parser for Zig. Single file, easy to use.

## Requirements
- zig 0.13.0

## Installation
You can just copy `argparse.zig` into your own repo, or add this repo as a Git
submodule and import from it.

(I'm not planning to make this as a Zig package)

## Usage
```zig
const argparse = @import("argparse.zig");
const ArgType = argparse.ArgType;
const ArgumentParser = argparse.ArgumentParser;

// Just an enum for demonstraion
const EnumType = enum { foo, bar };

// User-defined struct as a argument template, note that:
// - All positional arguments should be declared before non-positional ones
// - Single dash arguments taken as non-positional arguments
const ArgTmpl = struct {
    pos_str: ArgType("pos_str", []const u8, "", "Positional str"),
    opt_str_1: ArgType("-opt_str_1", []const u8, "default_opt_str_1", "Optional str 1"),
    opt_str_2: ArgType("--opt_str_1", []const u8, "default_opt_str_2", "Optional str 2"),
    opt_enum: ArgType("--opt_enum", EnumType, EnumType.bar, "Optional enum"),
    opt_bool: ArgType("--opt_bool", bool, false, "Optional bool"),
    opt_int: ArgType("--opt_int", i32, 10, "Optional int"),
    opt_uint: ArgType("--opt_uint", u64, 17, "Optional uint"),
    opt_float: ArgType("--opt_float", f32, 0.8, "Optional float"),
};

var arg_parser = argparse.ArgumentParser(ArgTmpl).init("prog");

const args = arg_parser.parse(argv) catch |err| switch (err) {
    // Gracefully exit when it's requested to print help message (no need
    // to call `printHelp()` again)
    ArgParseError.EndWithPrintingHelp => std.process.exit(0),
    // Print help and exit with non-zero code for other errors
    else => {
        arg_parser.printHelp();
        std.process.exit(1);
    },
};

// Value of parsed arguments can be accessed in this way:
std.debug.print("parsed opt_enum: {}\n", .{args.opt_enum.value});
```

You can also run `example.zig` to see how it work:
```bash
$ zig run example.zig -- foo.txt --opt_str_2=bar --opt_enum=foo --opt_int=-42 --opt_float=1.2
```

## Limitations
- Not supported types:
    - Array/ArrayList/Vector
    - Optional
    - Non-builtin types
- Subcommand is also not supported.
- Enum is supported, but it's case sensitive to the value. Like the example
  above, you cannot set `--opt_enum=FOO`.
- Only single flag for each argument, no aliasing.

Currently this parser is made to fit my own needs only, so it's really not
versatile like most of the other parsers, e.g., [zig-clap][gh-zig-clap],
[zig-cli][gh-zig-cli] ...

But please feel free to make them possible, even just for your own purpose.

## Postscript
- Why another argument parser?
    - For fun. It's also just a side product of my other project.
    - I'm exploring a way to manage multiple types generated by a generic
    type function (e.g., `ArgType()` in this implementation) without dynamic
    dispatch.
    - I had implemented [one parser based on tagged union][prev-argparse]
    before, but I'm not happy with it.

[gh-zig-clap]: https://github.com/Hejsil/zig-clap
[gh-zig-cli]: https://github.com/sam701/zig-cli
[prev-argparse]: https://gist.github.com/naleraphael/1cd99c4ea9aba5373bd5c022a432ee5a

