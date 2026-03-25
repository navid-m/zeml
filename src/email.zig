//! Email (.eml) parser module
const std = @import("std");
const testing = std.testing;

/// Represents a single email header
pub const EmailHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Represents a parsed email message
pub const Email = struct {
    headers: []EmailHeader,
    body: []const u8,

    /// Free allocated memory for headers and body
    pub fn deinit(self: *Email, allocator: std.mem.Allocator) void {
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
    // Determine separator length: \r\n\r\n = 4, \n\n = 2
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

    return Email{
        .headers = headers,
        .body = body,
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
}
