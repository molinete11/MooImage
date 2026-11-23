const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;


/// data: the actual pixels
/// depth: number of bits per channel
pub const MooImage = struct {
    data: []u8,
    width: u32,
    height: u32,
    channels: u32,
    depth: u32,

    pub fn free(self: *MooImage, gpa: Allocator) void{
        gpa.free(self.data);
    }
};


pub const png = @import("png.zig");