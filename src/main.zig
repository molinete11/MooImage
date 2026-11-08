const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = std.log;
const print = std.debug.print;
const debug = std.log.debug;
const readInt = std.mem.readInt;

const Decoder = struct {

    const Chunk = struct {
        len: u32,
        chunk_type: [4]u8,
        data: []u8,
        crc: [4]u8,
    };

    buffer: [1024]u8,
    reader: Io.File.Reader,
    file: Io.File,
    io: Io,
    allocator: std.mem.Allocator,

    pub fn init(self: *Decoder, io: Io, allocator: std.mem.Allocator, path: []const u8) !void{
        
        const dir = Io.Dir.cwd();

        self.allocator = allocator;
        self.file = try dir.openFile(io, path, .{});
        self.io = io;
        self.reader = self.file.reader(io, &self.buffer);
    }

    fn readChunk(self: *Decoder, chunk: *Chunk) !void{
        var r = &self.reader.interface;
        chunk.len = try r.takeInt(u32, .big);
        
        if(chunk.len >= std.math.maxInt(u31) - 1) return error.ChunkTooLarge;

        try r.readSliceEndian(u8, &chunk.chunk_type, .big);
        
        chunk.data = try r.readAllocAll(self.allocator, chunk.len);
        errdefer self.allocator.free(chunk.data);
        
        try r.readSliceEndian(u8, &chunk.crc, .big);
    }

    fn checkHeader(self: *Decoder) !void{
        const header = try self.reader.interface.takeInt(u64, .big);
        const signature: u64 = 0x89504E470D0A1A0A;

        log.debug("found: 0x{x}\n", .{header});
        log.debug("expected: 0x{x}\n", .{signature});
        if(header != signature) return error.NotAPNGImage;
    }

    pub fn read(self: *Decoder) !void{
        try self.checkHeader();

        var first_chunk: Chunk = undefined;

        try self.readChunk(&first_chunk);
        defer self.allocator.free(first_chunk.data);
        
        debug("len: {}\n", .{first_chunk.len});
        debug("type: ", .{});
        for(0..4) |i|{
            print("0x{x} ", .{first_chunk.chunk_type[i]});
        }
        print("\n", .{});

        debug("width: {}\n", .{readInt(u32, first_chunk.data[0..4], .big)});
        debug("heigth: {}\n", .{readInt(u32, first_chunk.data[4..8], .big)});
        debug("bit depth {}\n", .{first_chunk.data[8]});
        debug("color type {}\n", .{first_chunk.data[9]});
        debug("compression method {}\n", .{first_chunk.data[10]});
        debug("filter method {}\n", .{first_chunk.data[11]});
        debug("interlace method {}\n", .{first_chunk.data[12]});
    }

    pub fn deinit(self: *Decoder) void{
        self.file.close(self.io);
    }
};


pub fn main(init: std.process.Init) !void{
    const path = "image_test/file_example_PNG_500kB.png";

    var decoder: Decoder = undefined;
    try decoder.init(init.io, init.gpa, path);
    defer decoder.deinit();

    try decoder.read();
    
}