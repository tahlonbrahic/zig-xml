const std = @import("std");
const string = []const u8;
const Parser = @This();
const xml = @import("./root.zig");

allocator: std.mem.Allocator,
temp: std.ArrayListUnmanaged(u8) = .empty,
idx: usize = 0,
end: bool = false,
data: std.ArrayListUnmanaged(u32) = .empty,
string_bytes: std.ArrayListUnmanaged(u8) = .empty,
strings_map: std.StringArrayHashMapUnmanaged(xml.StringIndex) = .empty,
gentity_map: std.AutoArrayHashMapUnmanaged(xml.StringIndex, xml.StringIndex) = .empty,
pentity_map: std.AutoArrayHashMapUnmanaged(xml.StringIndex, xml.StringIndex) = .empty,
nodes: std.MultiArrayList(Node) = .empty,

pub fn avail(self: *Parser) usize {
    return self.temp.items.len - self.idx;
}

pub fn slice(self: *Parser) []const u8 {
    return self.temp.items[self.idx..];
}

pub fn eat(self: *Parser, comptime test_s: string) !?void {
    if (!try self.peek(test_s)) return null;
    self.idx += test_s.len;
}

pub fn peek(self: *Parser, comptime test_s: string) !bool {
    try self.peekAmt(test_s.len) orelse return false;
    if (test_s.len == 1) return self.slice()[0] == test_s[0];
    return std.mem.eql(u8, test_s, self.slice()[0..test_s.len]);
}

pub fn peekAmt(self: *Parser, comptime amt: usize) !?void {
    if (self.avail() >= amt) return;
    if (self.end) return null;

    const buf_size = std.heap.page_size_min;
    const diff_amt = amt - self.avail();
    std.debug.assert(diff_amt <= buf_size);

    var buf: [buf_size]u8 = undefined;
    // const len = try self.any.readAll(&buf); //TODO: replace me
    const len = std.mem.len(buf); //idk if this is ok

    if (len == 0) self.end = true;
    if (len == 0) return null;
    try self.temp.appendSlice(self.allocator, buf[0..len]);
    if (amt > len) return null;
}

pub fn eatByte(self: *Parser, test_c: u8) !?u8 {
    try self.peekAmt(1) orelse return null;
    if (self.slice()[0] == test_c) {
        defer self.idx += 1;
        return test_c;
    }
    return null;
}

pub fn eatRange(self: *Parser, comptime from: u8, comptime to: u8) !?u8 {
    try self.peekAmt(1) orelse return null;
    if (self.slice()[0] >= from and self.slice()[0] <= to) {
        defer self.idx += 1;
        return self.slice()[0];
    }
    return null;
}

pub fn eatRangeM(self: *Parser, comptime from: u21, comptime to: u21) !?u21 {
    const from_len = comptime std.unicode.utf8CodepointSequenceLength(from) catch unreachable;
    const to_len = comptime std.unicode.utf8CodepointSequenceLength(to) catch unreachable;
    const amt = @max(from_len, to_len);
    try self.peekAmt(amt) orelse return null;
    const len = std.unicode.utf8ByteSequenceLength(self.slice()[0]) catch return null;
    if (amt != len) return null;
    const mcp = std.unicode.utf8Decode(self.slice()[0..amt]) catch return null;
    if (mcp >= from and mcp <= to) {
        defer self.idx += len;
        return @intCast(mcp);
    }
    return null;
}

pub fn eatAny(self: *Parser, test_s: []const u8) !?u8 {
    try self.peekAmt(1) orelse return null;
    for (test_s) |c| {
        if (self.slice()[0] == c) {
            defer self.idx += 1;
            return c;
        }
    }
    return null;
}

pub fn eatAnyNot(self: *Parser, test_s: []const u8) !?u8 {
    try self.peekAmt(1) orelse return null;
    for (test_s) |c| {
        if (self.slice()[0] == c) {
            return null;
        }
    }
    defer self.idx += 1;
    return self.slice()[0];
}

pub fn eatQuoteS(self: *Parser) !?u8 {
    return self.eatAny(&.{ '"', '\'' });
}

pub fn eatQuoteE(self: *Parser, q: u8) !?void {
    return switch (q) {
        '"' => self.eat("\""),
        '\'' => self.eat("'"),
        else => unreachable,
    };
}

pub fn eatEnum(self: *Parser, comptime E: type) !?E {
    inline for (comptime std.meta.fieldNames(E)) |name| {
        if (try self.eat(name)) |_| {
            return @field(E, name);
        }
    }
    return null;
}

pub fn eatEnumU8(self: *Parser, comptime E: type) !?E {
    inline for (comptime std.meta.fieldNames(E)) |name| {
        if (try self.eatByte(@intFromEnum(@field(E, name)))) |_| {
            return @field(E, name);
        }
    }
    return null;
}

pub fn addStr(self: *Parser, alloc: std.mem.Allocator, str: string) !xml.StringIndex {
    const adapter: Adapter = .{ .self = self };
    const res = try self.strings_map.getOrPutAdapted(alloc, str, adapter);
    if (res.found_existing) return res.value_ptr.*;
    const q = self.string_bytes.items.len;
    try self.string_bytes.appendSlice(alloc, str);
    const r = self.data.items.len;
    try self.data.appendSlice(alloc, &[_]u32{ @as(u32, @intCast(q)), @as(u32, @intCast(str.len)) });
    res.value_ptr.* = @enumFromInt(r);
    return @enumFromInt(r);
}

const Adapter = struct {
    self: *const Parser,

    pub fn hash(ctx: @This(), a: string) u32 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(a);
        return @truncate(hasher.final());
    }

    pub fn eql(ctx: @This(), a: string, _: string, b_index: usize) bool {
        const sidx = ctx.self.strings_map.values()[b_index];
        const b = ctx.self.getStr(sidx);
        return std.mem.eql(u8, a, b);
    }
};

pub fn addStrList(self: *Parser, alloc: std.mem.Allocator, items: []const xml.StringIndex) !xml.StringListIndex {
    if (items.len == 0) return .empty;
    const r = self.data.items.len;
    try self.data.ensureUnusedCapacity(alloc, 1 + items.len);
    self.data.appendAssumeCapacity(@intCast(items.len));
    self.data.appendSliceAssumeCapacity(@ptrCast(items));
    return @enumFromInt(r);
}

pub fn getStr(self: *const Parser, sidx: xml.StringIndex) string {
    const obj = self.data.items[@intFromEnum(sidx)..][0..2].*;
    const str = self.string_bytes.items[obj[0]..][0..obj[1]];
    return str;
}

pub fn addElemNode(self: *Parser, alloc: std.mem.Allocator, ele: xml.Element) !xml.NodeIndex {
    const r = self.nodes.len;
    try self.nodes.append(alloc, .{ .element = ele });
    return @enumFromInt(r);
}

pub fn addTextNode(self: *Parser, alloc: std.mem.Allocator, txt: xml.StringIndex) !xml.NodeIndex {
    const r = self.nodes.len;
    try self.nodes.append(alloc, .{ .text = txt });
    return @enumFromInt(r);
}

pub fn addPINode(self: *Parser, alloc: std.mem.Allocator, pi: xml.ProcessingInstruction) !xml.NodeIndex {
    const r = self.nodes.len;
    try self.nodes.append(alloc, .{ .pi = pi });
    return @enumFromInt(r);
}

pub const Node = union(enum) {
    text: xml.StringIndex,
    element: xml.Element,
    pi: xml.ProcessingInstruction,
};

pub fn addNodeList(self: *Parser, alloc: std.mem.Allocator, items: []const xml.NodeIndex) !xml.NodeListIndex {
    if (items.len == 0) return .empty;
    const r = self.data.items.len;
    try self.data.ensureUnusedCapacity(alloc, 1 + items.len);
    self.data.appendAssumeCapacity(@intCast(items.len));
    self.data.appendSliceAssumeCapacity(@ptrCast(items));
    return @enumFromInt(r);
}
