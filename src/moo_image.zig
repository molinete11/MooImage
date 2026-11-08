const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Allocator = mem.Allocator;

const readInt = mem.readInt;


const png = @import("png.zig");

const Image = struct {
    buffer: []u8,
    width: usize,
    height: usize,
    channels: usize,

    pub fn free(self: *Image, allocator: Allocator) void{
        allocator.free(self.buffer);
    }
};

fn openFile(path: []const u8, io: Io) !Io.File{
    return try Io.Dir.cwd().openFile(io, path, .{});
}

pub fn loadPng(path: []const u8, io: Io, allocator: Allocator) !Image{
    var f = try openFile(path, io);

    var buffer: [2048]u8 = undefined;
    var freader = f.readerStreaming(io, &buffer);
    var r = &freader.interface;

    if(!png.validHeader(try r.takeInt(u64, .big))) return png.Error.InvalidHeader;

    var idhr: png.Chunk = undefined;
    try png.readChunk(r, allocator, &idhr);
    defer allocator.free(idhr.data);

    const width = readInt(u32, idhr.data[0..4], .big);
    const height = readInt(u32, idhr.data[4..8], .big);
    const bitdepth = idhr.data[8];
    const color_type = idhr.data[9];
    _ = bitdepth;
    _ = color_type;

    if(idhr.data[10] != 0) return png.Error.CompressionFormatNotSupported;

    var quit: bool = false;
    var image_lines: std.ArrayList([]u8) = .empty;
    var chunks: std.ArrayList(png.Chunk) = .empty;

    defer chunks.deinit(allocator);
    defer image_lines.deinit(allocator);
    
    defer for(0..chunks.items.len) |i|{
        allocator.free(chunks.items[i].data);
    };
    

    while(!quit) { // procesar IDAT chunks
        var chunk: png.Chunk = undefined;
        try png.readChunk(r, allocator, &chunk);
        try chunks.append(allocator, chunk);

        if(std.mem.eql(u8, &chunk.chunk_type, "IDAT")){    
            try image_lines.append(allocator, chunk.data);
        }

        if(png.isEnd(chunk.chunk_type)){
            quit = true;
        }
    }

    var image_compressed = try mem.concat(allocator, u8, image_lines.items);
    _ = &image_compressed;


    return .{
        .buffer = image_compressed,
        .width = width,
        .height = height,
        .channels = 3,
    };
}
