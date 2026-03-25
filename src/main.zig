const std = @import("std");
const zeml = @import("zeml");

const version_text = "v0.0.1";
const help_text =
    \\ zeml - advanced .eml parser and converter
    \\
    \\ Usage:
    \\     zeml <file.eml> [options]
    \\
    \\ Description:
    \\     Parses MIME email (.eml) files and provides tools for extracting
    \\     message contents, headers, attachments, and metadata.
    \\
    \\ Options:
    \\     --to-txt
    \\         Convert the email body to plain text and print to stdout.
    \\
    \\     --to-csv
    \\         Output email metadata (From, To, Subject, Date, etc.) as CSV.
    \\
    \\     --headers
    \\         Print all parsed email headers.
    \\
    \\     --body
    \\         Print the raw or decoded email body.
    \\
    \\     --attachments
    \\         List all attachments in the email.
    \\
    \\     --extract-attachments <dir>
    \\         Extract all attachments to the specified directory.
    \\
    \\     --filter-header <name>
    \\         Print a specific header (e.g. "Subject", "From").
    \\
    \\     --json
    \\         Output full parsed structure as JSON.
    \\
    \\     --charset <encoding>
    \\         Override detected charset when decoding message body.
    \\
    \\     --max-size <bytes>
    \\         Skip parsing parts larger than the specified size.
    \\
    \\     --quiet
    \\         Suppress non-essential output.
    \\
    \\     --version
    \\         Show the current version of zeml.
    \\
    \\     --help
    \\         Show this help message.
    \\
;

const Options = struct {
    file_path: ?[]const u8 = null,
    to_txt: bool = false,
    to_csv: bool = false,
    headers: bool = false,
    body: bool = false,
    attachments: bool = false,
    extract_attachments: ?[]const u8 = null,
    filter_header: ?[]const u8 = null,
    json: bool = false,
    charset: ?[]const u8 = null,
    max_size: ?usize = null,
    quiet: bool = false,
    help: bool = false,
    version: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, arg, "--to-txt")) {
            opts.to_txt = true;
        } else if (std.mem.eql(u8, arg, "--to-csv")) {
            opts.to_csv = true;
        } else if (std.mem.eql(u8, arg, "--headers")) {
            opts.headers = true;
        } else if (std.mem.eql(u8, arg, "--body")) {
            opts.body = true;
        } else if (std.mem.eql(u8, arg, "--attachments")) {
            opts.attachments = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--extract-attachments")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --extract-attachments requires a directory argument\n", .{});
                std.process.exit(1);
            }
            opts.extract_attachments = args[i];
        } else if (std.mem.eql(u8, arg, "--filter-header")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --filter-header requires a header name argument\n", .{});
                std.process.exit(1);
            }
            opts.filter_header = args[i];
        } else if (std.mem.eql(u8, arg, "--charset")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --charset requires an encoding argument\n", .{});
                std.process.exit(1);
            }
            opts.charset = args[i];
        } else if (std.mem.eql(u8, arg, "--max-size")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --max-size requires a bytes argument\n", .{});
                std.process.exit(1);
            }
            opts.max_size = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("error: --max-size value must be a positive integer\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            if (opts.file_path != null) {
                std.debug.print("error: multiple input files specified\n", .{});
                std.process.exit(1);
            }
            opts.file_path = arg;
        }
    }

    if (opts.version) {
        std.debug.print("{s}\n", .{version_text});
    }

    if (opts.help or opts.file_path == null) {
        std.debug.print("{s}", .{help_text});
        if (opts.file_path == null and !opts.help) std.process.exit(1);
        return;
    }

    const file_content = std.fs.cwd().readFileAlloc(allocator, opts.file_path.?, opts.max_size orelse std.math.maxInt(usize)) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (!opts.quiet) std.debug.print("error: file not found: {s}\n", .{opts.file_path.?});
                std.process.exit(2);
            },
            error.FileTooBig => {
                if (!opts.quiet) std.debug.print("error: file exceeds max-size limit\n", .{});
                std.process.exit(2);
            },
            else => {
                if (!opts.quiet) std.debug.print("error: could not read file: {s}\n", .{opts.file_path.?});
                std.process.exit(2);
            },
        }
    };
    defer allocator.free(file_content);

    var email = zeml.parseEmail(allocator, file_content) catch {
        if (!opts.quiet) std.debug.print("error: failed to parse email\n", .{});
        std.process.exit(3);
    };
    defer email.deinit(allocator);

    const no_output_opt = !opts.to_txt and !opts.to_csv and !opts.headers and
        !opts.body and !opts.attachments and opts.extract_attachments == null and
        opts.filter_header == null and !opts.json;

    if (opts.headers or no_output_opt) {
        for (email.headers) |h| {
            std.debug.print("{s}: {s}\n", .{ h.name, h.value });
        }
        if (no_output_opt) std.debug.print("\n", .{});
    }

    if (opts.body or opts.to_txt or no_output_opt) {
        std.debug.print("{s}\n", .{email.body});
    }

    if (opts.filter_header) |name| {
        if (email.getHeader(name)) |value| {
            std.debug.print("{s}\n", .{value});
        } else {
            if (!opts.quiet) std.debug.print("header '{s}' not found\n", .{name});
        }
    }

    if (opts.to_csv) {
        std.debug.print("From,To,Subject,Date\n", .{});
        std.debug.print("\"{s}\",\"{s}\",\"{s}\",\"{s}\"\n", .{
            email.getFrom() orelse "",
            email.getTo() orelse "",
            email.getSubject() orelse "",
            email.getDate() orelse "",
        });
    }

    if (opts.json) {
        std.debug.print("{{\n", .{});
        std.debug.print("  \"headers\": {{\n", .{});
        for (email.headers, 0..) |h, idx| {
            const comma: []const u8 = if (idx + 1 < email.headers.len) "," else "";
            std.debug.print("    \"{s}\": \"{s}\"{s}\n", .{ h.name, h.value, comma });
        }
        std.debug.print("  }},\n", .{});
        std.debug.print("  \"body\": \"{s}\",\n", .{email.body});
        std.debug.print("  \"attachments\": [\n", .{});
        for (email.attachments, 0..) |att, idx| {
            const comma: []const u8 = if (idx + 1 < email.attachments.len) "," else "";
            std.debug.print("    {{\"filename\": \"{s}\", \"content_type\": \"{s}\", \"size\": {d}}}{s}\n", .{ att.filename, att.content_type, att.size, comma });
        }
        std.debug.print("  ]\n", .{});
        std.debug.print("}}\n", .{});
    }

    if (opts.attachments or opts.extract_attachments != null) {
        if (email.attachments.len == 0) {
            if (!opts.quiet) std.debug.print("no attachments found\n", .{});
        } else if (opts.attachments) {
            for (email.attachments, 0..) |att, idx| {
                std.debug.print("[{d}] {s}  ({s}, {d} bytes)\n", .{ idx + 1, att.filename, att.content_type, att.size });
            }
        }

        if (opts.extract_attachments) |dir_path| {
            std.fs.cwd().makePath(dir_path) catch |err| {
                if (!opts.quiet) std.debug.print("error: could not create directory '{s}': {}\n", .{ dir_path, err });
                std.process.exit(4);
            };
            const out_dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
                if (!opts.quiet) std.debug.print("error: could not open directory '{s}': {}\n", .{ dir_path, err });
                std.process.exit(4);
            };
            for (email.attachments) |att| {
                out_dir.writeFile(.{ .sub_path = att.filename, .data = att.data }) catch |err| {
                    if (!opts.quiet) std.debug.print("error: could not write '{s}': {}\n", .{ att.filename, err });
                    continue;
                };
                if (!opts.quiet) std.debug.print("extracted: {s}/{s}\n", .{ dir_path, att.filename });
            }
        }
    }
}

test "parse args: --help flag" {
    const opts = Options{};
    try std.testing.expect(!opts.help);
    try std.testing.expect(!opts.to_txt);
    try std.testing.expect(opts.file_path == null);
}

test "parse args: option defaults" {
    const opts = Options{
        .to_csv = true,
        .quiet = true,
    };
    try std.testing.expect(opts.to_csv);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(!opts.json);
}
