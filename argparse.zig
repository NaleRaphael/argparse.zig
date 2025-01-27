const std = @import("std");
const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const expectErr = std.testing.expectError;

pub const ArgParseError = error{
    TooManyPositionals,
    UnknownArgument,
    // PositionalAfterOptional, // check in comptime
    InvalidValue,
    // InvalidFlag, // check in comptime
    TooFewPositionalsToParse,
    EndWithPrintingHelp,
    UnsupportedType, // mostly check in comptime
};

fn strToBool(raw: []const u8) ArgParseError!bool {
    var buf: [5]u8 = undefined;
    if (raw.len > 5) {
        std.debug.print("Invalid value \"{s}\" for boolean\n", .{raw});
        return ArgParseError.InvalidValue;
    }

    const out = std.ascii.lowerString(&buf, raw);
    if (std.mem.eql(u8, out, "true")) {
        return true;
    } else if (std.mem.eql(u8, out, "false")) {
        return false;
    } else {
        std.debug.print("Invalid value \"{s}\" for boolean\n", .{raw});
        return ArgParseError.InvalidValue;
    }
}

fn strToEnum(comptime T: type, raw: []const u8) ArgParseError!T {
    if (std.meta.stringToEnum(T, raw)) |val| {
        return val;
    } else {
        std.debug.print("Invalid value \"{s}\" for enum type {}\n", .{ raw, T });
        return ArgParseError.InvalidValue;
    }
}

inline fn compErr(comptime fmt: []const u8, args: anytype) void {
    @compileError(std.fmt.comptimePrint(fmt, args));
}

pub fn ArgType(flag: []const u8, comptime T: type, value: T, desc: []const u8) type {
    comptime {
        const ti = @typeInfo(T);
        switch (ti) {
            .Bool, .Int, .Float, .Enum => {},
            .Pointer => {
                // Only `[]const u8` is supported
                if (ti.Pointer.size != .Slice or ti.Pointer.child != u8) {
                    compErr("Unsupported type \"{}\" for {s}\n", .{ T, flag });
                }
            },
            else => compErr("Unsupported type \"{}\" for {s}\n", .{ T, flag }),
        }
    }
    return struct {
        flag: []const u8 = flag,
        desc: []const u8 = desc,
        value: T = value,

        const Self = @This();

        pub fn update(self: *Self, raw: []const u8) !void {
            const ti = @typeInfo(T);
            switch (ti) {
                .Bool => self.value = try strToBool(raw),
                .Int => self.value = std.fmt.parseInt(T, raw, 10) catch {
                    std.debug.print("Invalid value \"{s}\" for int\n", .{raw});
                    return ArgParseError.InvalidValue;
                },
                .Float => self.value = std.fmt.parseFloat(T, raw) catch {
                    std.debug.print("Invalid value \"{s}\" for float\n", .{raw});
                    return ArgParseError.InvalidValue;
                },
                .Enum => self.value = try strToEnum(T, raw),
                .Pointer => {
                    if (ti.Pointer.size == .Slice and ti.Pointer.child == u8) {
                        self.value = raw;
                    } else {
                        return ArgParseError.UnsupportedType;
                    }
                },
                else => return ArgParseError.UnsupportedType,
            }
        }
    };
}

/// Reify an argument template (user-defined struct).
/// See also the definition of `std.builtin.Type.StructField` to understand how
/// this function works.
pub fn reifyArgTmpl(comptime Tmpl: type) Tmpl {
    var args: Tmpl = undefined;

    // Iterate over the fields in given template, and initialize them.
    inline for (std.meta.fields(Tmpl)) |arg| {
        var arg_value: arg.type = undefined;

        // Iterate over the fields in user-defined `ArgType()`, and initialize
        // fields with its default value.
        inline for (std.meta.fields(arg.type)) |f| {
            const init_val = @as(*align(1) const f.type, @ptrCast(f.default_value)).*;
            @field(arg_value, f.name) = init_val;
        }

        @field(args, arg.name) = arg_value;
    }

    return args;
}

/// Get default value of a struct field.
/// This is a borrowed implementation from the lastest branch (Zig > 0.13.0):
/// https://github.com/ziglang/zig/blob/3767b08/lib/std/builtin.zig#L672-L677
fn getDefaultValue(comptime sf: std.builtin.Type.StructField) ?sf.type {
    const dp: *const sf.type = @ptrCast(@alignCast(sf.default_value orelse return null));
    return dp.*;
}

/// Check whether a flag is for positional argument.
fn isPositional(flag: []const u8) bool {
    return !std.mem.startsWith(u8, flag, "-");
}

fn isValidFlag(comptime flag: []const u8) bool {
    const prefixed = std.mem.startsWith;
    var plen: u32 = 0;

    if (flag.len == 0) return false;

    if (prefixed(u8, flag, "--")) {
        if (flag.len == 2) return false;
        plen = 2;
    } else if (prefixed(u8, flag, "-")) {
        if (flag.len == 1) return false;
        plen = 1;
    }

    for (flag[plen..], plen..flag.len) |c, i| {
        // Whitelist: [a-zA-Z0-9\-\_]
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            continue;
        }
        if (c == '-' and i != flag.len - 1) {
            continue;
        }
        return false;
    }
    return true;
}

/// A generic function to create an argument parser type based on user-defined
/// struct.
///
/// The input template `Tmpl` should contains fields with type generated by
/// `ArgType()` only. e.g.,
/// ```zig
/// const ArgTmpl = struct {
///     file: ArgType("file", []const u8", "default.txt", "Input file"),
///     lines: ArgType("--lines", u32, 10, "Lines to show"),
/// };
/// ```
pub fn ArgumentParser(comptime Tmpl: type) type {
    // Do the following checks in comptime:
    // - All positional arguments should be defined before non-positional ones
    // - Flag name
    // - Unsupported argument type (e.g., pointer)
    // - Duplicated flags
    comptime {
        var no_more_positional = false;
        const fields = std.meta.fields(Tmpl);

        // NOTE: field order is guaranteed during comptime reflection, so we can
        // check the declaration order according to it. (don't get confused with
        // the in-memory layout of `packed struct`, see also the link below)
        // https://discord.com/channels/605571803288698900/1299673987164536892/1299673987164536892
        for (fields, 0..fields.len) |arg, i| {
            const arg_t = arg.type;

            // XXX: If compiler failed at this line, it means some fields
            // in given template are not generated by `ArgType()`. Since
            // we cannot validate those fields with specific type, we have
            // to rely on this mechanism for now.
            const sf = std.meta.fieldInfo(arg_t, .flag);

            const flag: []const u8 = getDefaultValue(sf) orelse "";
            if (!isValidFlag(flag)) {
                compErr("Invalid flag for argument: {s}\n", .{arg.name});
            }

            const is_positional = isPositional(flag);
            if (no_more_positional and is_positional) {
                compErr("Found positional argument after non-positionals: \"{s}\"\n", .{flag});
            }
            no_more_positional = !is_positional;

            // Check duplicated flags
            for (fields[0..i]) |f| {
                const prev = std.meta.fieldInfo(f.type, .flag);
                const prev_flag: []const u8 = getDefaultValue(prev) orelse "";
                if (std.mem.eql(u8, flag, prev_flag)) {
                    compErr("Found duplicated flag in \"{s}\" and \"{s}\"\n", .{ arg.name, f.name });
                }
            }
        }
    }

    return struct {
        prog: []const u8,
        args: Tmpl,
        _cnt_positionals: u32,
        _cnt_parsed_positionals: u32,

        const Self = @This();

        pub fn init(prog: []const u8) Self {
            const args = reifyArgTmpl(Tmpl);

            var cnt: u32 = 0;
            inline for (std.meta.fields(Tmpl)) |arg| {
                const flag = @field(args, arg.name).flag;
                cnt += @intFromBool(isPositional(flag));
            }

            return .{
                .prog = prog,
                .args = args,
                ._cnt_positionals = cnt,
                ._cnt_parsed_positionals = 0,
            };
        }

        pub fn printHelp(self: Self) void {
            const fields = std.meta.fields(Tmpl);

            std.debug.print("USAGE: {s}", .{self.prog});
            inline for (fields) |arg| {
                const flag = @field(self.args, arg.name).flag;
                if (isPositional(flag)) {
                    std.debug.print(" {s}", .{arg.name});
                }
            }
            std.debug.print(" [options]\n", .{});

            std.debug.print("OPTIONS:\n", .{});
            inline for (fields) |arg| {
                const v = @field(self.args, arg.name);
                std.debug.print("  {s}\t {s}\n", .{ v.flag, v.desc });
            }
        }

        pub fn parse(self: *Self, argv: [][]const u8) ArgParseError!Tmpl {
            if (argv.len == 1 and self._cnt_positionals == 0) {
                return self.args;
            }
            if ((argv.len - 1) < self._cnt_positionals) {
                std.debug.print("It seems not all positional arguments are specified.\n", .{});
                return ArgParseError.TooFewPositionalsToParse;
            }

            for (argv[1..]) |raw_arg| {
                self.parseSingle(raw_arg) catch |err| switch (err) {
                    ArgParseError.EndWithPrintingHelp => {
                        self.printHelp();
                        return err;
                    },
                    else => return err,
                };
            }
            return self.args;
        }

        fn parseSingle(self: *Self, raw_arg: []const u8) ArgParseError!void {
            if (std.mem.eql(u8, raw_arg, "-h") or std.mem.eql(u8, raw_arg, "--help")) {
                return ArgParseError.EndWithPrintingHelp;
            }

            if (isPositional(raw_arg)) {
                return try self.parsePositional(raw_arg);
            } else {
                if (self._cnt_parsed_positionals < self._cnt_positionals) {
                    std.debug.print("It seems not all positional arguments are specified.\n", .{});
                    return ArgParseError.TooFewPositionalsToParse;
                }
                return try self.parseNonPositional(raw_arg);
            }
        }

        fn parsePositional(self: *Self, raw_arg: []const u8) ArgParseError!void {
            if (self._cnt_parsed_positionals >= self._cnt_positionals) {
                std.debug.print("Found extra positional argument to parse: {s}.\n", .{raw_arg});
                return ArgParseError.TooManyPositionals;
            }

            const idx = self._cnt_parsed_positionals;
            const fields = std.meta.fields(Tmpl);

            // NOTE: We have to access field like this
            inline for (fields, 0..fields.len) |f, i| {
                if (idx == i) {
                    // Update arg (`ArgType()`)
                    try @field(self.args, f.name).update(raw_arg);
                }
            }
            self._cnt_parsed_positionals += 1;
        }

        /// Non-positional argument should be always specified as below:
        /// - "-NAME=VALUE"
        /// - "--NAME=VALUE"
        fn parseNonPositional(self: *Self, raw_arg: []const u8) ArgParseError!void {
            const fields = std.meta.fields(Tmpl);
            inline for (fields) |f| {
                var arg = &@field(self.args, f.name);
                const flag: []const u8 = arg.flag;

                if (raw_arg.len > flag.len + 1 and
                    std.mem.eql(u8, raw_arg[0..flag.len], flag) and
                    raw_arg[flag.len] == '=')
                {
                    const raw_val = raw_arg[flag.len + 1 ..];
                    return try arg.update(raw_val);
                }
            }

            std.debug.print("Unknown argument to parse: {s}.\n", .{raw_arg});
            return ArgParseError.UnknownArgument;
        }
    };
}

pub fn showParsedArgs(comptime T: type, args_inst: T) void {
    std.debug.print("===== Parsed args =====\n", .{});

    const args = std.meta.fields(T);
    inline for (args, 0..args.len) |f, i| {
        std.debug.print("[{d}] {s} : ", .{ i, f.name });

        const arg = @field(args_inst, f.name);
        const val_ti = @typeInfo(@TypeOf(arg.value));
        switch (val_ti) {
            .Pointer => {
                if (val_ti.Pointer.size == .Slice) {
                    std.debug.print("{s}\n", .{arg.value});
                } else {
                    std.debug.print("{any}\n", .{arg.value});
                }
            },
            else => std.debug.print("{any}\n", .{arg.value}),
        }
    }
    std.debug.print("=======================\n", .{});
}

test "test_all_arg_types_and_print_help" {
    const ActionType = enum { READ, WRITE };

    var argv = [_][]const u8{
        "this_bin",
        "positional_str",
        "-opt_str_1=optional_1",
        "--opt_bool=true",
        "--opt_uint=42",
        "--opt_int=-42",
        "--opt_float=-17.0",
        "--opt_enum=READ",
    };

    const ArgTmpl = struct {
        pos_str: ArgType("pos_str", []const u8, "", "Positional str"),
        opt_str_1: ArgType("-opt_str_1", []const u8, "default_opt_str_1", "Optional str 1"),
        opt_str_2: ArgType("--opt_str_1", []const u8, "default_opt_str_2", "Optional str 2"),
        opt_enum: ArgType("--opt_enum", ActionType, ActionType.WRITE, "Optional enum"),
        opt_bool: ArgType("--opt_bool", bool, false, "Optional bool"),
        opt_int: ArgType("--opt_int", i32, 10, "Optional int"),
        opt_uint: ArgType("--opt_uint", u64, 17, "Optional uint"),
        opt_float: ArgType("--opt_float", f32, 0.8, "Optional float"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const args = arg_parser.parse(&argv) catch |err| switch (err) {
        ArgParseError.EndWithPrintingHelp => return,
        else => return err,
    };

    try expect(arg_parser._cnt_positionals == 1);
    try expect(std.mem.eql(u8, args.pos_str.value, "positional_str"));
    try expect(std.mem.eql(u8, args.opt_str_1.value, "optional_1"));
    try expect(std.mem.eql(u8, args.opt_str_2.value, "default_opt_str_2"));
    try expect(args.opt_enum.value == ActionType.READ);
    try expect(args.opt_bool.value == true);
    try expect(args.opt_int.value == -42);
    try expect(args.opt_uint.value == 42);
    try expect(std.math.approxEqAbs(f32, args.opt_float.value, -17.0, 1e-6));
}

test "expect_error_TooManyPositionals" {
    var argv = [_][]const u8{
        "this_bin",
        "positional_str",
        "extra_positional",
    };

    const ArgTmpl = struct {
        pos_str: ArgType("pos_str", []const u8, "", "Positional str"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const res = arg_parser.parse(&argv);

    // There is only 1 positional argument defined ("pos_str"), but there are
    // 2 positional arguments supplied to parse.
    try expectErr(ArgParseError.TooManyPositionals, res);
}

test "expect_error_UnknownArgument" {
    var argv = [_][]const u8{
        "this_bin",
        "--opt_integer=3",
    };

    const ArgTmpl = struct {
        opt_int: ArgType("--opt_int", i32, 0, "Optional int"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const res = arg_parser.parse(&argv);

    // Name of optional argument is expected to be "--opt_int", but it's
    // "--opt_integer" in this case.
    try expectErr(ArgParseError.UnknownArgument, res);
}

// // This case is expected to trigger a comptime error: "Found positional
// // argument after non-positionals".
// test "expect_error_PositionalAfterOptional" {
//     const ArgTmpl = struct {
//         opt_int: ArgType("--opt_int", i32, 0, "Optional int"),
//         pos_bool: ArgType("pos_bool", bool, true, "Positional bool"),
//     };
//     const arg_parser = ArgumentParser(ArgTmpl).init("prog");
//     _ = arg_parser;
// }

// // This case is expected to trigger a comptime error: "Invalid flag for
// // argument {}".
// test "expect_error_InvalidFlag" {
//     const ArgTmpl = struct {
//         invalid_01: ArgType("", i32, 0, "Empty flag"),
//         invalid_02: ArgType("flag@#$%^&*()[]{}/'\";", i32, 0, "Contains invalid characters"),
//         invalid_03: ArgType("--", i32, 0, "Only two dashes"),
//         invalid_04: ArgType("-", i32, 0, "Only one dash"),
//         invalid_05: ArgType("--flag-", i32, 0, "Ends with a dash"),
//     };
//     const arg_parser = ArgumentParser(ArgTmpl).init("prog");
//     _ = arg_parser;
// }

test "expect_error_InvalidValue" {
    const EnumType = enum { foo, bar };
    const ArgTmpl = struct {
        opt_bool: ArgType("--opt_bool", bool, false, "Optional bool"),
        opt_int: ArgType("--opt_int", i32, 10, "Optional int"),
        opt_uint: ArgType("--opt_uint", u64, 17, "Optional uint"),
        opt_float: ArgType("--opt_float", f32, 0.8, "Optional float"),
        opt_enum: ArgType("--opt_enum", EnumType, EnumType.bar, "Optional enum"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");

    var argv_01 = [_][]const u8{ "this_bin", "--opt_int=abc" };
    try expectErr(ArgParseError.InvalidValue, arg_parser.parse(&argv_01));

    var argv_02 = [_][]const u8{ "this_bin", "--opt_uint=-10" };
    try expectErr(ArgParseError.InvalidValue, arg_parser.parse(&argv_02));

    var argv_03 = [_][]const u8{ "this_bin", "--opt_float=0..1" };
    try expectErr(ArgParseError.InvalidValue, arg_parser.parse(&argv_03));

    // Boolean value should be passed as string: { "true", "false" }.
    var argv_04 = [_][]const u8{ "this_bin", "--opt_bool=1" };
    try expectErr(ArgParseError.InvalidValue, arg_parser.parse(&argv_04));

    var argv_05 = [_][]const u8{ "this_bin", "--opt_enum=buzz" };
    try expectErr(ArgParseError.InvalidValue, arg_parser.parse(&argv_05));
}

// // Optional is not supported.
// test "expect_error_UnsupportedType_1" {
//     const ArgTmpl = struct {
//         opt_ptr: ArgType("--opt_ptr", ?*i32, null, "Optional optional"),
//     };
//
//     var arg_parser = ArgumentParser(ArgTmpl).init("prog");
//
//     var argv = [_][]const u8{ "this_bin", "--opt_ptr=foobar" };
//     const res = try arg_parser.parse(&argv);
//     _ = res;
// }

// // Pointer is not supported.
// test "expect_error_UnsupportedType_2" {
//     const ArgTmpl = struct {
//         var a: i32 = 0;
//         opt_ptr: ArgType("--opt_ptr", *i32, &a, "Optional pointer"),
//     };
//
//     var arg_parser = ArgumentParser(ArgTmpl).init("prog");
//
//     var argv = [_][]const u8{ "this_bin", "--opt_ptr=foobar" };
//     const res = try arg_parser.parse(&argv);
//     _ = res;
// }

// // Duplicated flags in different arguments. (expected to be a compile error)
// test "expect_error_DuplicatedFlag" {
//     var argv = [_][]const u8{"this_bin"};
//     const ArgTmpl = struct {
//         opt1: ArgType("--opt1", i32, 0, "Optional int 1"),
//         opt2: ArgType("--opt1", i32, 0, "Optional int 2"),
//     };
//
//     var arg_parser = ArgumentParser(ArgTmpl).init("prog");
//     const res = try arg_parser.parse(&argv);
//     _ = res;
// }

test "expect_error_TooFewPositionalsToParse_1" {
    var argv = [_][]const u8{ "this_bin", "1" };
    const ArgTmpl = struct {
        pos_int_1: ArgType("pos_int_1", i32, 0, "Positional int 1"),
        pos_int_2: ArgType("pos_int_2", i32, 0, "Positional int 2"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const res = arg_parser.parse(&argv);

    // There are 2 positional arguments defined, but only 1 positional argument
    // is supplied. The parser should validate that all positional arguments
    // are consumed before `parse()` is done.
    try expectErr(ArgParseError.TooFewPositionalsToParse, res);
}

test "expect_error_TooFewPositionalsToParse_2" {
    var argv = [_][]const u8{ "this_bin", "1", "--opt_int=3", "3" };
    const ArgTmpl = struct {
        pos_int_1: ArgType("pos_int_1", i32, 0, "Positional int 1"),
        pos_int_2: ArgType("pos_int_2", i32, 0, "Positional int 2"),
        opt_int: ArgType("--opt_int", i32, 0, "Optional int"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const res = arg_parser.parse(&argv);

    // While the parser is processing the optional argument "--opt_int", there
    // is still one positional argument need to be processed. Since all
    // positional arguments should be supplied before optional arguments, this
    // case should fail.
    try expectErr(ArgParseError.TooFewPositionalsToParse, res);
}

test "expect_error_EndWithPrintingHelp_1" {
    var argv = [_][]const u8{ "this_bin", "--help" };

    const ArgTmpl = struct {};

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const res = arg_parser.parse(&argv);
    try expectErr(ArgParseError.EndWithPrintingHelp, res);
}

test "expect_error_EndWithPrintingHelp_2" {
    var argv = [_][]const u8{ "this_bin", "1", "--help", "--opt_int=1" };

    const ArgTmpl = struct {
        pos_int: ArgType("pos_int", i32, 0, "Positional int"),
        opt_int: ArgType("--opt_int", i32, 0, "Optional int"),
    };

    var arg_parser = ArgumentParser(ArgTmpl).init("prog");
    const res = arg_parser.parse(&argv);

    // No matter the order of "--help" is supplied, the parser should stop
    // right after finding it's supplied.
    try expectErr(ArgParseError.EndWithPrintingHelp, res);
}
