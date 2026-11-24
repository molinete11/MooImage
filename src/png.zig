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
    biggest_ll_length: u16 = 0,
    biggest_d_length: u16 = 0,

    d_count: u16 = 0,
    ll_count: u16 = 0,

    ll_symbols: [285]Symbol = bk: {
        var s: [285]Symbol = undefined;

        for(0..s.len) |i|{
            s[i].name = i;
            s[i].len = 0;
            s[i].code = 0;
        }

        break :bk s;
    }, 

    d_symbols: [32]Symbol = bk: {
        var s: [32]Symbol = undefined;

        for(0..s.len) |i|{
            s[i].name = i;
            s[i].len = 0;
            s[i].code = 0;
        }

        break :bk s;
    }
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

const Symbol = struct{
    name: u15 = 0,
    code: u15 = 0,
    len: u4 = 0,
};

const readInt = mem.readInt;

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

    var t = Io.Clock.awake.now(io);

    try readZlib(compressed_data, filtered_image);

    const time = t.untilNow(io, .awake).toNanoseconds();

    std.debug.print("readZlib {} ms\n", 
            .{@as(f64, @floatFromInt(@as(i64, @truncate(time)))) / 1000000});

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
    
    var t = Io.Clock.awake.now(_io); 

    try decodeDeflate(&stream, buffer);

    const time = t.untilNow(_io, .awake).toNanoseconds();

    std.debug.print("deflate {} ms\n", 
            .{@as(f64, @floatFromInt(@as(i64, @truncate(time)))) / 1000000});
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
                try decode(
                    &huffman_codes.ll_symbols, 
                    huffman_codes.ll_count, 
                    huffman_codes.biggest_ll_length, 
                    stream);
        
            if(symbol < end_of_block){
                //print("byte(curr byte => {}) {}\n", .{curr_byte, symbol});
                @branchHint(.likely);
 
                buffer[curr_byte] = @intCast(symbol);
                curr_byte += 1;

            }else if(symbol > end_of_block){

                const length = 
                    try decodeLength(symbol, stream);

                const d_symbol = 
                    try decode(
                        &huffman_codes.d_symbols, 
                        huffman_codes.d_count,
                        huffman_codes.biggest_d_length, 
                        stream);

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
    var hclen: u16 = @as(u16, @intCast(try stream.read(4))) + 4;

    var cl_symbols = comptime bk: {
        var symbols: [19]Symbol = undefined;
        const cl_names = [_]u15{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
        
        for(0..19) |i|{
            symbols[i].name = cl_names[i];
            symbols[i].code = 0;
            symbols[i].len = 0;
        }

        break :bk symbols;
    };

    for(0..hclen)|i|{
        cl_symbols[i].len = @intCast(try stream.read(3));
    }

    sort(&cl_symbols, &hclen); // sort by name
    
    genHuffmanCodes(&cl_symbols, hclen);

    std.sort.block(Symbol, cl_symbols[0..hclen], cl_symbols, struct{
        fn f(ctx: @TypeOf(cl_symbols), lhs: Symbol, rhs: Symbol) bool{
            _ = ctx;
            return lhs.code < rhs.code;
        }}.f
    );

    const biggest_cl_lenght = cl_symbols[hclen - 1].len; 


    //for(0..hclen) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
    //    cl_symbols[i].name,
    //    cl_symbols[i].code,
    //    cl_symbols[i].len,
    //});

    var h_codes = HuffmanPrefixCodes{
        .d_count = hdist + 1,
        .ll_count = hlit + 257,
    };

    var code_lengths: [317]u4 = @splat(0);
    var code_len: usize = 0;

    while(code_len < hlit+hdist+258){

        const code_symbol = try decode(&cl_symbols, hclen, biggest_cl_lenght, stream);
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

    for(0..h_codes.ll_count) |i| h_codes.ll_symbols[i].len = code_lengths[i];
    for(0..h_codes.d_count) |i| h_codes.d_symbols[i].len = code_lengths[h_codes.ll_count + i];

    sort(&h_codes.ll_symbols, &h_codes.ll_count); 
    sort(&h_codes.d_symbols, &h_codes.d_count); 

    genHuffmanCodes(&h_codes.ll_symbols, h_codes.ll_count);
    genHuffmanCodes(&h_codes.d_symbols, h_codes.d_count);

    std.sort.block(Symbol, h_codes.ll_symbols[0..h_codes.ll_count],
    {}, 
    struct{
        fn f(_: void, lhs: Symbol, rhs: Symbol) bool{

            return lhs.code < rhs.code;
        }}.f
    );

    std.sort.block(Symbol, h_codes.d_symbols[0..h_codes.d_count],
    {}, 
    struct{
        fn f(_: void, lhs: Symbol, rhs: Symbol) bool{
            return lhs.code < rhs.code;
        }}.f
    );

    h_codes.biggest_ll_length = h_codes.ll_symbols[h_codes.ll_count - 1].len;
    h_codes.biggest_d_length = h_codes.d_symbols[h_codes.d_count - 1].len;

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


fn decode(symbols: []Symbol, n: u16, biggest: u16, stream: *BitStream) !u15{

    const max_code =  try stream.peek(biggest);

    const mask_table = comptime bk: {
        var masks: [16]u16 = undefined;

        for (0..16) |i| {
            masks[i] = ~(-%(@as(u16, 1) << @intCast(i)));
        }

        break :bk masks;
    };

    for(0..n)|i|{
        const len = symbols[i].len;

        if(len != 0 and 
            (reverse(len, (max_code & mask_table[len]))) == symbols[i].code){

            stream.toss(len);
            
            return symbols[i].name;
        }
    }
    
    return error.SymbolNotFound;
}

fn sort(symbols: []Symbol, new_len: *u16) void{
    for(0..symbols.len) |i|{
        const s = symbols[i];

        if(s.len == 0){
            var j: usize = symbols.len - 1;
            while(j > i and symbols[j].len == 0):(j -= 1){}
            if(i == j) {
                new_len.* = @intCast(j);
                break;
            }

            symbols[i] = symbols[j];
            symbols[j] = s;
        }
    }


    std.sort.block(Symbol, symbols[0..new_len.*], symbols, struct{
        fn f(ctx: []Symbol, lhs: Symbol, rhs: Symbol) bool{
            _ = ctx;
            return lhs.name < rhs.name;
        }}.f
    );
    
}

inline fn reverse(len: usize, bits: u16) u16{
    const extra = 16 - len;

    return @bitReverse(bits) >> @intCast(extra);
}

inline fn genHuffmanCodes(symbols: []Symbol, n: usize) void{
    var bl_count: [19]usize = @splat(0);
    var max_bits: usize = 0; 
    var next_code: [19]u15 = @splat(0);

    for(0..n) |i|{
        bl_count[symbols[i].len] += 1;
        if(symbols[i].len > max_bits) max_bits = symbols[i].len;
    }
    
    var code: u15 = 0;
    bl_count[0] = 0;
    for(1..max_bits+1) |bits|{
        code = (code + @as(u15, @intCast(bl_count[bits - 1]))) << 1;
        next_code[bits] = code;
    }
    
    for(0..n) |i|{
        symbols[i].code = next_code[symbols[i].len];
        next_code[symbols[i].len] += 1;
    }
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
