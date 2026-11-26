const std = @import("std");
const MooImage = @import("moo_image.zig").MooImage;
const builtin = @import("builtin");
const mem = std.mem;
const Io = std.Io;
const Allocator = mem.Allocator;

const Chunk = struct {
    len: u32 = 0,
    ctype: [4]u8 = undefined,
    data: []u8 = undefined,
    crc: [4]u8 = undefined,
};

const Cmf = packed struct {
    cm: u4 = 0,
    cinfo: u4 = 0,
};

const Flg = packed struct {
    fcheck: u5 = 0,
    fdict: u1 = 0,
    flevel: u2 = 0,
};

const HuffmanPrefixCodes = struct{
    ll_symbols: LlSymbols = .{}, 
    d_symbols: DSymbols = .{},
};

const BitStream = struct {
    buffer: []const u8 = undefined,
    bits_consumed: usize = 0,

    fn skipCurrentByte(self: *BitStream) void{
        self.bits_consumed += 8 - (self.bits_consumed & 7);
    }

    fn read(self: *BitStream, n: usize) !u16{
        const ret = try self.peek(n);
        self.toss(n);
        return ret;
    }


    fn peek(self: *BitStream, bits: usize) !u16{
        @setRuntimeSafety(false);
        if(bits == 0) return 0;
        if(self.bits_consumed + bits > self.buffer.len * 8) {@branchHint(.unlikely); return error.OutOfBounds;}

        const byte_idx = self.bits_consumed >> 3;
        const bit_idx = self.bits_consumed & 7;
        
        var buffer: u24 = self.buffer[byte_idx];

        if(bit_idx + bits > 8){
            buffer |= @as(u24, self.buffer[byte_idx + 1]) << 8;

            if(bit_idx + bits > 16){
                buffer |= @as(u24, self.buffer[byte_idx + 2]) << 16;
            }
        }

        const mask: u16 = ~(-%(@as(u16, 1) << @intCast(bits)));
        return @as(u16, @truncate((buffer >> @intCast(bit_idx)))) & mask;

    }


    fn toss(self: *BitStream, bits: usize) void{
        self.bits_consumed += bits;
    }
};

const DeflateHeaderBlock = packed struct {
    bfinal: u1 = 0, // last block?
    btype: u2 = 0, // 0 -> uncompressed, 1 -> fixed huffman codes, 2 -> custom huffman codes
};

fn Symbols(size: comptime_int) type{
    return struct {

        const Self = @This();

        sortByName: bool = true,

        biggest_len: u4 = 0,

        count: u16 = 0,

        name: [size]u15 = bk: {
            var s: [size]u15 = undefined;

            for(0..s.len) |i|{
                s[i] = i;
            }

            break :bk s;
        },
        code: [size]u15 = @splat(0),
        clen: [size]u4 = @splat(0),
        table: [32768]u15 = @splat(0),

        pub fn initWithCustomNames(names: *const [size]u15) Self{
            comptime var self: Self = .{};
            
            inline for(0..size) |i|{
                self.name[i] = names[i];
            }

            return self;
        }
        
        pub fn swap(self: *Self, i: usize, j: usize) void{
            if(i == j) return;
            const len = self.clen[i];
            const code = self.code[i];
            const name = self.name[i];

            self.clen[i] = self.clen[j]; 
            self.code[i] = self.code[j];
            self.name[i] = self.name[j];

            self.clen[j] = len;
            self.code[j] = code;
            self.name[j] = name;
        }

        pub fn lessThan(self: *Self, i: usize, j: usize) bool{
            if(i == j) return false;
            
            return if(self.clen[i] == self.clen[j]) 
                return self.name[i] < self.name[j] else
                return self.clen[i] < self.clen[j]; 
        }

        pub fn sort(self: *Self) void{
            for(0..self.count) |i|{
                const len = self.clen[i];

                if(len == 0){
                    var j: usize = self.count - 1;
                    while(j > i and self.clen[j] == 0):(j -= 1){}
                    if(i == j) {
                        self.count = @intCast(j);
                        break;
                    }
                    
                    self.swap(i, j);
                }
            }


            std.sort.heapContext(0, self.count, self); 
            self.biggest_len = self.clen[self.count - 1];
        }

        pub fn decode(self: *Self, stream: *BitStream) !u15{

            const max_code =  try stream.peek(self.biggest_len);

            const mask_table = comptime bk: {
                var masks: [16]u16 = undefined;

                for (0..16) |i| {
                    masks[i] = ~(-%(@as(u16, 1) << @intCast(i)));
                }

                break :bk masks;
            };

            for(0..self.count)|i|{
                const len = self.clen[i];

                if(len != 0 and 
                    (reverse(len, (max_code & mask_table[len]))) == self.code[i]){

                    stream.toss(len);
                    
                    return self.name[i];
                }
            }

            return error.SymbolNotFound;
        }

        pub fn genHuffmanCodes(self: *Self) void{
            var bl_count: [19]usize = @splat(0);
            var max_bits: usize = 0; 
            var next_code: [19]u15 = @splat(0);

            for(0..self.count) |i|{
                const len = self.clen[i];
                bl_count[len] += 1;
                if(len > max_bits) max_bits = len;
            }
            
            var code: u15 = 0;
            bl_count[0] = 0;
            for(1..max_bits+1) |bits|{
                code = (code + @as(u15, @intCast(bl_count[bits - 1]))) << 1;
                next_code[bits] = code;
            }
            
            for(0..self.count) |i|{
                const len = self.clen[i];
                self.code[i] = next_code[len];
                next_code[len] += 1;
            }
        }
    };
}

const LlSymbols = Symbols(285);
const DSymbols = Symbols(32);
const CLSymbols = Symbols(19);

const readInt = mem.readInt;
const print = std.debug.print;

const end_of_block: u15 = 256;
const is_little_endian = builtin.cpu.arch.endian() == .little;

var _io: std.Io = undefined; // for debugging
/// path -> relative
pub fn load(path: []const u8, gpa: Allocator, io: Io) !MooImage{
    _io = io;

    var buff: [4096]u8 = undefined;
    var f = try Io.Dir.cwd().openFile(io, path, .{});
    var fr = f.readerStreaming(io, &buff);
    var r = &fr.interface;

    // READ HEADER
    try r.discardAll(8); // skip header

    // HEADER PNG
    var idhr = Chunk{};
    try readChunk(r, gpa, &idhr);
    defer gpa.free(idhr.data);
    // Opcional ver si hay chunks que no son IDAT y no sean criticos

    const width = readInt(u32, idhr.data[0..4], .big);
    const height = readInt(u32, idhr.data[4..8], .big);
    const bitdepth = idhr.data[8];
    const color_type = idhr.data[9];
    _ = color_type;
    
    const filtered_image = try gpa.alloc(u8, height * (1 + width * 3));
    defer gpa.free(filtered_image);

    const image = try gpa.alloc(u8, height * width * 3);

    const compressed_data: []u8 = try readCompressedData(r, gpa);
    defer gpa.free(compressed_data);


    try readZlib(compressed_data, filtered_image);


    try unfilter(filtered_image, image, width * 3, height);

    return .{
        .channels = 0,
        .width = width,
        .height = height,
        .depth = bitdepth,
        .data = image,
    };
}

fn unfilter(data: []u8, out: []u8, stride: usize, n_scanlines: usize) !void{
    var r = Io.Reader.fixed(data);

    if(data.len != (n_scanlines * (1 + stride))) return error.SUS;
    if(out.len != (stride * n_scanlines)) return error.SUS2;

    for (0..n_scanlines) |i| {
        const filter_type = try r.takeByte();

        for(0..stride) |j|{

            const curr_byte: usize = i * stride + j;

            const prev_scan = if(i == 0) 0 else (i - 1) * stride + j;

            const x = try r.takeByte();
            const a: u8 = if(j < 3) 0 else out[curr_byte - 3];
            const b: u8 = if(i == 0) 0 else out[prev_scan];
            const c: u8 = if(i == 0 or j < 3) 0 else out[prev_scan - 3];

            const unfiltered_byte = switch (filter_type) {
                0 => x,
                1 => x +% a,
                2 => x +% b,
                3 => x +% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
                4 => x +% paeth(a, b, c),
                else => return error.InvalidFilter
            };

            out[curr_byte] = unfiltered_byte;
        }   
    }
}

fn paeth(a: u8, b: u8, c: u8) u8{
    const p = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if(pa <= pb and pa <= pc)return a;
    if(pb <= pc)return b;
    return c;

}

fn readZlib(data: []u8, buffer: []u8) !void{
   
    const cmf: Cmf = @bitCast(data[0]);
    const flg: Flg = @bitCast(data[1]);
    _ = cmf;
    _ = flg;
    var stream = BitStream{.buffer = data[2..data.len-@sizeOf(u32)]};

    try decodeDeflate(&stream, buffer);

}

// bloque 2
// 1. leer length de los length symbols 3 bits cada uno
// 2. generar los codigos usando codigos huffman https://www.rfc-editor.org/info/rfc1951/
// 3. leer las longitudes de los literal/length codes y distance codes
// 4. repetir 2
// decode compressed data with tables generetated in 4
//
// cosas a tener en cuenta
//

fn decodeDeflate(stream: *BitStream, buffer: []u8) !void{

    var last: bool = false;
    var curr_byte: usize = 0;
    while(!last){
        const h: DeflateHeaderBlock = try readDeflateHeaderBlock(stream);
        //print("{}\n", .{h});
        var huffman_codes = HuffmanPrefixCodes{};

        if(h.bfinal == 1) {last = true;}

        if(h.btype == 0){}
        else if(h.btype == 2){
            huffman_codes = try readCustomHuffmanPrefixCodes(stream);   
        }
        
 
        while(true){
            const symbol = 
                try huffman_codes.ll_symbols.decode(stream);
        
            if(symbol < end_of_block){
                //print("byte(curr byte => {}) {}\n", .{curr_byte, symbol});
                @branchHint(.likely);
 
                buffer[curr_byte] = @intCast(symbol);
                curr_byte += 1;

            }else if(symbol > end_of_block){

                const length = 
                    try decodeLength(symbol, stream);

                const d_symbol = 
                    try huffman_codes.d_symbols.decode(stream);

                const distance = 
                    try decodeDistance(d_symbol, stream);

                //print("pair length({}) {}, distance({}) {}\n", .{symbol, length, d_symbol, distance});


                const start = curr_byte - distance;

                if(length > distance){

                    const slice = buffer[start..curr_byte];
                    @memcpy(buffer[curr_byte..(curr_byte + distance)], slice);

                    const start_overlap = (curr_byte + distance);
                    const new_len = length - distance;
                    for(0..new_len) |i| buffer[start_overlap + i] = buffer[curr_byte + i];
                }else{

                    const end = start + length;

                    const slice = buffer[start..end];
                    @memcpy(buffer[curr_byte..curr_byte+length], slice);
                }

                curr_byte += length;
            }else{
                @branchHint(.unlikely);
                break;
            }
            
        }
    }
}


fn readCustomHuffmanPrefixCodes(stream: *BitStream) !HuffmanPrefixCodes{
    const hlit: u16 = @intCast(try stream.read(5));
    const hdist: u16 = @intCast(try stream.read(5));
    const hclen: u16 = @as(u16, @intCast(try stream.read(4))) + 4;

    const cl_names = [_]u15{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

    var cl_symbols: CLSymbols = comptime .initWithCustomNames(&cl_names);
    cl_symbols.count = hclen;

    for(0..cl_symbols.count)|i|{
        cl_symbols.clen[i] = @intCast(try stream.read(3));
    }
    
    cl_symbols.sort();
    
    cl_symbols.genHuffmanCodes();


    //for(0..hclen) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
    //    cl_symbols.name[i],
    //    cl_symbols.code[i],
    //    cl_symbols.clen[i],
    //});

    var h_codes = HuffmanPrefixCodes{
        .d_symbols = .{ .count = hdist + 1 },
        .ll_symbols = .{ .count = hlit + 257 },
    };

    var code_lengths: [317]u4 = @splat(0);
    var code_len: usize = 0;

    while(code_len < hlit+hdist+258){

        const code_symbol = 
            try cl_symbols.decode(stream);

        if(code_symbol <= 15){

            code_lengths[code_len] = @intCast(code_symbol);
            code_len += 1;

        }else if(code_symbol == 16){

            const prev = code_lengths[code_len - 1];
            const rep = try stream.read(2) + 3;
            for(0..rep) |j|{
                code_lengths[code_len + j] = prev;
            }
            code_len += rep;

        }else if(code_symbol == 17){ // can skip

            const repeat = try stream.read(3) + 3;
            code_len += repeat;

        }else if(code_symbol == 18){ // can skip

            const repeat = try stream.read(7) + 11;
            code_len += repeat;

        }
        
    }

    const lenl = h_codes.ll_symbols.count;
    const lend = h_codes.d_symbols.count;

    @memcpy(h_codes.ll_symbols.clen[0..lenl], code_lengths[0..lenl]);
    @memcpy(h_codes.d_symbols.clen[0..lend], code_lengths[lenl..lenl + lend]);
    
    h_codes.ll_symbols.sort();
    h_codes.d_symbols.sort();

    h_codes.ll_symbols.genHuffmanCodes();
    h_codes.d_symbols.genHuffmanCodes();


    //for(0..h_codes.ll_count) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
    //    h_codes.ll_symbols[i].name,
    //    h_codes.ll_symbols[i].code,
    //    h_codes.ll_symbols[i].len,
    //});

    //for(0..h_codes.d_count) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
    //    h_codes.d_symbols[i].name,
    //    h_codes.d_symbols[i].code,
    //    h_codes.d_symbols[i].len,
    //});

    return h_codes;
}

fn decodeDistance(symbol: u15, stream: *BitStream) !u16{
    const distance_table = [_]u16{
        1, 2, 3, 4, 5, 7, 9, 13,
        17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537,
        2049, 3073, 4097, 6145, 8193, 12289,
        16385, 24577,
    };

    const extra_bits = [_]u8{
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3,
        4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
        9, 9, 10, 10, 11, 11, 12, 12,
        13, 13,
    };

    const start_distance = distance_table[symbol];
    
    const offset = try stream.read(extra_bits[symbol]);

    return start_distance + offset;
}

fn decodeLength(symbol: u15, stream: *BitStream) !u16{

    const length_table = [_]u16{
        3, 4, 5, 6, 7, 8, 9, 10,
        11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227, 258,
    };

    const extra_bits = [_]u16{
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 0,
    };

    const i = symbol - 257;

    const start_len = length_table[i];

    const offset = try stream.read(extra_bits[i]);

    return start_len + offset;
}



inline fn reverse(len: usize, bits: u16) u16{
    const extra = 16 - len;

    return @bitReverse(bits) >> @intCast(extra);
}



/// Leer chunks criticos
/// IDAT 
/// PLTE
/// IEND
fn readCompressedData(r: *Io.Reader, gpa: Allocator) ![]u8{
    
    var chunk_data: std.ArrayList(u8) = .empty;

    while(true){
        var chunk = Chunk{};

        chunk.len = try r.takeInt(u32, .big);
        
        if(chunk.len >= std.math.maxInt(u31) - 1) return error.ChunkTooLarge;

        try r.readSliceEndian(u8, &chunk.ctype, .big);

        if(!mem.eql(u8, &chunk.ctype, "IDAT")) {
            try r.discardAll(chunk.len + 4);

            if(mem.eql(u8, &chunk.ctype, "IEND")) break;
            continue;
        }
        
        const data = try r.readAllocAll(gpa, chunk.len);
        defer gpa.free(data);
        try chunk_data.appendSlice(gpa, data);
        
        // TODO: check corruption
        try r.readSliceEndian(u8, &chunk.crc, .big);
        
    }

    return try chunk_data.toOwnedSlice(gpa);
}

fn readChunk(r: *Io.Reader, allocator: Allocator, chunk: *Chunk) !void{
    chunk.len = try r.takeInt(u32, .big);
    
    if(chunk.len >= std.math.maxInt(u31) - 1) return error.ChunkTooLarge;

    try r.readSliceEndian(u8, &chunk.ctype, .big);
    
    chunk.data = try r.readAllocAll(allocator, chunk.len);
    errdefer allocator.free(chunk.data);
    
    try r.readSliceEndian(u8, &chunk.crc, .big);
}

fn readDeflateHeaderBlock(stream: *BitStream) !DeflateHeaderBlock{
    return @bitCast(@as(u3, @intCast(try stream.read(3))));
}
