//! Email (.eml) parser module
const std = @import("std");
const testing = std.testing;

/// Represents a single email header
pub const EmailHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Represents a decoded email attachment
pub const Attachment = struct {
    filename: []const u8,
    content_type: []const u8,
    data: []const u8, // owned, must be freed
    size: usize,

    pub fn deinit(self: *Attachment, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Represents a parsed email message
pub const Email = struct {
    headers: []EmailHeader,
    body: []const u8,
    attachments: []Attachment,

    /// Free allocated memory for headers, body, and attachments
    pub fn deinit(self: *Email, allocator: std.mem.Allocator) void {
        for (self.attachments) |*att| {
            att.deinit(allocator);
        }
        allocator.free(self.attachments);
        allocator.free(self.headers);
    }

    /// Get a header value by name (case-insensitive)
    pub fn getHeader(self: *const Email, name: []const u8) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    /// Get the From header value
    pub fn getFrom(self: *const Email) ?[]const u8 {
        return self.getHeader("From");
    }

    /// Get the To header value
    pub fn getTo(self: *const Email) ?[]const u8 {
        return self.getHeader("To");
    }

    /// Get the Subject header value
    pub fn getSubject(self: *const Email) ?[]const u8 {
        return self.getHeader("Subject");
    }

    /// Get the Date header value
    pub fn getDate(self: *const Email) ?[]const u8 {
        return self.getHeader("Date");
    }
};

/// Parse error set for email parsing
pub const ParseError = error{
    InvalidFormat,
    OutOfMemory,
};

/// Extract the boundary parameter from a Content-Type value like
/// "multipart/mixed; boundary=\"abc\""
fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const needle = "boundary=";
    const idx = std.ascii.indexOfIgnoreCase(content_type, needle) orelse return null;
    var val = content_type[idx + needle.len ..];
    if (val.len > 0 and val[0] == '"') {
        val = val[1..];
        const end = std.mem.indexOfScalar(u8, val, '"') orelse val.len;
        return val[0..end];
    }
    var end: usize = 0;
    while (end < val.len and val[end] != ';' and val[end] != ' ' and val[end] != '\t' and val[end] != '\r' and val[end] != '\n') {
        end += 1;
    }
    return if (end > 0) val[0..end] else null;
}

/// Extract a parameter value from a header value string, e.g. filename="foo.txt"
fn extractParam(header_val: []const u8, param: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (param.len + 1 > buf.len) return null;
    @memcpy(buf[0..param.len], param);
    buf[param.len] = '=';
    const needle = buf[0 .. param.len + 1];
    const idx = std.ascii.indexOfIgnoreCase(header_val, needle) orelse return null;
    var val = header_val[idx + needle.len ..];
    if (val.len > 0 and val[0] == '"') {
        val = val[1..];
        const end = std.mem.indexOfScalar(u8, val, '"') orelse val.len;
        return val[0..end];
    }
    var end: usize = 0;
    while (end < val.len and val[end] != ';' and val[end] != ' ' and val[end] != '\t' and val[end] != '\r' and val[end] != '\n') {
        end += 1;
    }
    return if (end > 0) val[0..end] else null;
}

/// Decode base64-encoded data, stripping whitespace first.
fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ParseError![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    for (encoded) |c| {
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') {
            clean.append(allocator, c) catch return ParseError.OutOfMemory;
        }
    }
    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(clean.items) catch return ParseError.InvalidFormat;
    const out = allocator.alloc(u8, dec_len) catch return ParseError.OutOfMemory;
    std.base64.standard.Decoder.decode(out, clean.items) catch {
        allocator.free(out);
        return ParseError.InvalidFormat;
    };
    return out;
}

/// Parse MIME parts from a multipart body given the boundary string.
/// Appends Attachment entries to `list` for parts with Content-Disposition: attachment
/// or inline parts that have a filename.
fn parseMultipart(
    allocator: std.mem.Allocator,
    body: []const u8,
    boundary: []const u8,
    list: *std.ArrayList(Attachment),
) ParseError!void {
    const delim = std.fmt.allocPrint(allocator, "--{s}", .{boundary}) catch return ParseError.OutOfMemory;
    defer allocator.free(delim);

    var pos: usize = 0;
    pos = std.mem.indexOf(u8, body, delim) orelse return;
    pos += delim.len;
    if (pos < body.len and body[pos] == '\r') pos += 1;
    if (pos < body.len and body[pos] == '\n') pos += 1;

    while (pos < body.len) {
        const next = std.mem.indexOf(u8, body[pos..], delim) orelse break;
        const part_raw = body[pos .. pos + next];
        pos = pos + next + delim.len;
        const is_last = pos + 1 < body.len and body[pos] == '-' and body[pos + 1] == '-';

        if (pos < body.len and body[pos] == '\r') pos += 1;
        if (pos < body.len and body[pos] == '\n') pos += 1;

        var part_header_end: usize = 0;
        var pi: usize = 0;
        while (pi < part_raw.len) {
            if (pi + 3 < part_raw.len and part_raw[pi] == '\r' and part_raw[pi + 1] == '\n' and part_raw[pi + 2] == '\r' and part_raw[pi + 3] == '\n') {
                part_header_end = pi;
                pi += 4;
                break;
            } else if (pi + 1 < part_raw.len and part_raw[pi] == '\n' and part_raw[pi + 1] == '\n') {
                part_header_end = pi;
                pi += 2;
                break;
            }
            pi += 1;
        }

        const part_headers_raw = part_raw[0..part_header_end];
        var part_body = part_raw[pi..];
        part_body = trimWhitespace(part_body);

        var content_type: []const u8 = "application/octet-stream";
        var content_disposition: []const u8 = "";
        var transfer_encoding: []const u8 = "";
        var filename: []const u8 = "";

        var ls: usize = 0;
        while (ls < part_headers_raw.len) {
            const le = findLineEnd(part_headers_raw, ls);
            const line = trimWhitespace(part_headers_raw[ls..le]);
            if (line.len > 0) {
                const ci = std.mem.indexOfScalar(u8, line, ':') orelse {
                    ls = skipToNextLine(part_headers_raw, le);
                    continue;
                };
                const hname = trimWhitespace(line[0..ci]);
                const hval = if (ci + 1 < line.len) trimWhitespace(line[ci + 1 ..]) else "";
                if (std.ascii.eqlIgnoreCase(hname, "Content-Type")) {
                    content_type = hval;
                    if (filename.len == 0) {
                        if (extractParam(hval, "name")) |n| filename = n;
                    }
                } else if (std.ascii.eqlIgnoreCase(hname, "Content-Disposition")) {
                    content_disposition = hval;
                    if (extractParam(hval, "filename")) |n| filename = n;
                } else if (std.ascii.eqlIgnoreCase(hname, "Content-Transfer-Encoding")) {
                    transfer_encoding = hval;
                }
            }
            ls = skipToNextLine(part_headers_raw, le);
        }

        if (std.ascii.startsWithIgnoreCase(content_type, "multipart/")) {
            if (extractBoundary(content_type)) |sub_boundary| {
                try parseMultipart(allocator, part_body, sub_boundary, list);
            }
            if (is_last) break;
            continue;
        }

        const is_attachment = std.ascii.startsWithIgnoreCase(content_disposition, "attachment");
        const has_filename = filename.len > 0;
        if (!is_attachment and !has_filename) {
            if (is_last) break;
            continue;
        }

        const data = if (std.ascii.eqlIgnoreCase(trimWhitespace(transfer_encoding), "base64"))
            try decodeBase64(allocator, part_body)
        else blk: {
            const copy = allocator.dupe(u8, part_body) catch return ParseError.OutOfMemory;
            break :blk copy;
        };

        const fname_copy = if (filename.len > 0)
            allocator.dupe(u8, filename) catch {
                allocator.free(data);
                return ParseError.OutOfMemory;
            }
        else
            allocator.dupe(u8, "attachment") catch {
                allocator.free(data);
                return ParseError.OutOfMemory;
            };

        const ct_copy = allocator.dupe(u8, content_type) catch {
            allocator.free(data);
            allocator.free(fname_copy);
            return ParseError.OutOfMemory;
        };

        list.append(allocator, .{
            .filename = fname_copy,
            .content_type = ct_copy,
            .data = data,
            .size = data.len,
        }) catch {
            allocator.free(data);
            allocator.free(fname_copy);
            allocator.free(ct_copy);
            return ParseError.OutOfMemory;
        };

        if (is_last) break;
    }
}

/// Parse an .eml file content into an Email struct
/// The input must remain valid for the lifetime of the returned Email
pub fn parseEmail(allocator: std.mem.Allocator, input: []const u8) ParseError!Email {
    var header_end: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (i + 2 < input.len and input[i] == '\r' and input[i + 1] == '\n' and input[i + 2] == '\r' and input[i + 3] == '\n') {
            header_end = i;
            break;
        } else if (i + 1 < input.len and input[i] == '\n' and input[i + 1] == '\n') {
            header_end = i;
            break;
        }
        i += 1;
    }

    const headers_section = input[0..header_end];
    const sep_len: usize = if (header_end + 1 < input.len and input[header_end] == '\r') 4 else 2;
    const body = if (header_end + sep_len <= input.len) input[header_end + sep_len ..] else "";

    var header_count: usize = 0;
    var line_start: usize = 0;

    while (line_start < headers_section.len) {
        const line_end = findLineEnd(headers_section, line_start);
        if (line_end > line_start) {
            header_count += 1;
        }
        line_start = line_end + 1;
    }

    const headers = try allocator.alloc(EmailHeader, header_count);
    errdefer allocator.free(headers);

    var header_idx: usize = 0;
    line_start = 0;
    while (line_start < headers_section.len and header_idx < header_count) {
        const line_end = findLineEnd(headers_section, line_start);
        if (line_end > line_start) {
            const line = trimWhitespace(headers_section[line_start..line_end]);
            if (line.len > 0) {
                const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse {
                    line_start = skipToNextLine(headers_section, line_end);
                    continue;
                };

                const name = trimWhitespace(line[0..colon_idx]);
                const value = if (colon_idx + 1 < line.len)
                    trimWhitespace(line[colon_idx + 1 ..])
                else
                    "";

                headers[header_idx] = .{
                    .name = name,
                    .value = value,
                };
                header_idx += 1;
            }
        }
        line_start = skipToNextLine(headers_section, line_end);
    }

    var attachments: std.ArrayList(Attachment) = .empty;
    errdefer {
        for (attachments.items) |*att| att.deinit(allocator);
        attachments.deinit(allocator);
    }

    const ct_header = blk: {
        for (headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) break :blk h.value;
        }
        break :blk @as([]const u8, "");
    };

    if (std.ascii.startsWithIgnoreCase(ct_header, "multipart/")) {
        if (extractBoundary(ct_header)) |boundary| {
            try parseMultipart(allocator, body, boundary, &attachments);
        }
    }

    const attachments_slice = try attachments.toOwnedSlice(allocator);

    return Email{
        .headers = headers,
        .body = body,
        .attachments = attachments_slice,
    };
}

fn findLineEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        if (text[i] == '\n') {
            return i;
        }
        i += 1;
    }
    return text.len;
}

fn skipToNextLine(text: []const u8, line_end: usize) usize {
    _ = text;
    return line_end + 1;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;

    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) {
        start += 1;
    }

    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) {
        end -= 1;
    }

    return s[start..end];
}

test "parse simple email" {
    const email_content =
        \\From: sender@example.com
        \\To: recipient@example.com
        \\Subject: Test Email
        \\Date: Mon, 1 Jan 2024 00:00:00 +0000
        \\
        \\Hello, this is the email body.
    ;

    var email = try parseEmail(testing.allocator, email_content);
    defer email.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), email.headers.len);
    try testing.expectEqualStrings("sender@example.com", email.getFrom().?);
    try testing.expectEqualStrings("recipient@example.com", email.getTo().?);
    try testing.expectEqualStrings("Test Email", email.getSubject().?);
    try testing.expectEqualStrings("Hello, this is the email body.", email.body);
}

test "parse email with CRLF" {
    const email_content = "From: test@example.com\r\nSubject: CRLF Test\r\n\r\nBody text";

    var email = try parseEmail(testing.allocator, email_content);
    defer email.deinit(testing.allocator);

    try testing.expectEqualStrings("test@example.com", email.getFrom().?);
    try testing.expectEqualStrings("CRLF Test", email.getSubject().?);
    try testing.expectEqualStrings("Body text", email.body);
}

test "getHeader case insensitive" {
    const email_content =
        \\FROM: upper@example.com
        \\to: lower@example.com
        \\
        \\Body
    ;

    var email = try parseEmail(testing.allocator, email_content);
    defer email.deinit(testing.allocator);

    try testing.expectEqualStrings("upper@example.com", email.getHeader("from").?);
    try testing.expectEqualStrings("lower@example.com", email.getHeader("TO").?);
}

test "parse email with empty body" {
    const email_content = "Subject: No body\r\n\r\n";

    var email = try parseEmail(testing.allocator, email_content);
    defer email.deinit(testing.allocator);

    try testing.expectEqualStrings("", email.body);
    try testing.expectEqual(@as(usize, 0), email.attachments.len);
}

test "parse multipart email with attachment" {
    const email_content =
        "From: sender@example.com\r\n" ++
        "To: recipient@example.com\r\n" ++
        "Subject: Multipart Test\r\n" ++
        "Content-Type: multipart/mixed; boundary=\"boundary42\"\r\n" ++
        "\r\n" ++
        "--boundary42\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Hello world\r\n" ++
        "--boundary42\r\n" ++
        "Content-Type: text/plain; name=\"hello.txt\"\r\n" ++
        "Content-Disposition: attachment; filename=\"hello.txt\"\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "\r\n" ++
        "SGVsbG8sIFdvcmxkIQ==\r\n" ++
        "--boundary42--\r\n";

    var email = try parseEmail(testing.allocator, email_content);
    defer email.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), email.attachments.len);
    try testing.expectEqualStrings("hello.txt", email.attachments[0].filename);
    try testing.expectEqualStrings("Hello, World!", email.attachments[0].data);
}

test "parse multipart email no attachments" {
    const email_content =
        "Content-Type: multipart/mixed; boundary=\"b\"\r\n" ++
        "\r\n" ++
        "--b\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Just text\r\n" ++
        "--b--\r\n";

    var email = try parseEmail(testing.allocator, email_content);
    defer email.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), email.attachments.len);
}
