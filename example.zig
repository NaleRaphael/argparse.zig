const std = @import("std");
const argparse = @import("argparse.zig");

const ArgType = argparse.ArgType;
const ArgParseError = argparse.ArgParseError;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Just an enum for demonstration
    const EnumType = enum { foo, bar };

    // User-defined struct as a argument template, note that:
    // - All positional arguments should be declared before non-positional ones
    // - Single dash arguments taken as non-positional arguments
    const ArgTmpl = struct {
        pos_str: ArgType("pos_str", []const u8, "", "Positional str"),
        opt_str_1: ArgType("-opt_str_1", []const u8, "default_opt_str_1", "Optional str 1"),
        opt_str_2: ArgType("--opt_str_2", []const u8, "default_opt_str_2", "Optional str 2"),
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

    // A helper function to print parsed arguments
    argparse.showParsedArgs(ArgTmpl, args);

    // Value of parsed arguments can be accessed in this way:
    std.debug.print("parsed opt_enum: {}\n", .{args.opt_enum.value});
}
