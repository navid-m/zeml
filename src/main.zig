const std = @import("std");
const zeml = @import("zeml");

pub fn main() !void {
    std.debug.print(
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
        \\     --help
        \\         Show this help message.
        \\
        \\ Exit Codes:
        \\     0  Success
        \\     1  Invalid arguments
        \\     2  File not found / unreadable
        \\     3  Parse error
        \\
    , .{});
}
