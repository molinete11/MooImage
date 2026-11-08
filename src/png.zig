const std = @import("std");
const Io = std.Io;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Error = error{
    InvalidHeader,
    CompressionFormatNotSupported,
};

pub const Chunk = struct {
    len: u32,
    chunk_type: [4]u8,
    data: []u8,
    crc: [4]u8,
};

pub fn validHeader(header: u64) bool{
    const signature: u64 = 0x89504E470D0A1A0A;
    if(header != signature) return false;
    return true;
}

pub fn isEnd(chunk_type: [4]u8) bool{
    return mem.eql(u8, &chunk_type, "IEND");
}

pub fn readChunk(r: *Io.Reader, allocator: Allocator ,chunk: *Chunk) !void{
    chunk.len = try r.takeInt(u32, .big);
    
    if(chunk.len >= std.math.maxInt(u31) - 1) return error.ChunkTooLarge;

    try r.readSliceEndian(u8, &chunk.chunk_type, .big);
    
    chunk.data = try r.readAllocAll(allocator, chunk.len);
    errdefer allocator.free(chunk.data);
    
    try r.readSliceEndian(u8, &chunk.crc, .big);
}

