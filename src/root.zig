//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const email = @import("email.zig");
pub const Email = email.Email;
pub const EmailHeader = email.EmailHeader;
pub const Attachment = email.Attachment;
pub const parseEmail = email.parseEmail;
