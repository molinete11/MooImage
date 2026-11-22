const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

const is_little_endian = builtin.cpu.arch.endian() == .little;

const print = std.debug.print;
const readInt = std.mem.readInt;

pub fn main(init: std.process.Init) !void{
    const io = init.io;
    const gpa = init.gpa;
    const path: []const u8 = "image_test/file_example_PNG_500kB.png";
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
    
    const out_image = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(out_image);
    

    const compressed_data: []u8 = try readCompressedData(r, gpa);
    defer gpa.free(compressed_data);

    try readZlib(compressed_data, out_image);


    var test_buff: [1024]u8 = undefined;
    var f2 = try Io.Dir.cwd().createFile(init.io, "image_test/test.ppm", .{});
    defer f2.close(init.io);
    var fw = f2.writer(init.io, &test_buff);
    var w = &fw.interface;
    try w.print("P6\n{} {}\n255\n", .{width, height});
    _ = try w.write(out_image);
}

const Chunk = struct {
    len: u32 = 0,
    type: [4]u8 = undefined,
    data: []u8 = undefined,
    crc: [4]u8 = undefined,
};

pub const Cmf = packed struct {
    cm: u4 = 0,
    cinfo: u4 = 0,
};

pub const Flg = packed struct {
    fcheck: u5 = 0,
    fdict: u1 = 0,
    flevel: u2 = 0,
};


const HuffmanPrefixCodes = struct{
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

        fn peek8(self: *const BitStream, bits: usize) !u8{
            @setRuntimeSafety(false);
            if(bits == 0) return 0;
            if(bits > 8) return error.BiggerThanExpected;
            if(self.bits_consumed + bits > self.buffer.len * 8) return error.OutOfBounds;

            const byte_idx = self.bits_consumed >> 3;
            const bit_idx = self.bits_consumed & 7;

            var buffer: u8 = 0;

            if(bit_idx + bits > 8){
                const first_len = 8 - bit_idx;
                const second_len = bits - first_len;
                {
                    const mask: u8 = @truncate(~(-%(@as(u16, 1) << @intCast(first_len))));
                    buffer |= (self.buffer[byte_idx] >> @intCast(bit_idx)) & mask;
                }
                {
                    const mask: u8 = @truncate(~(-%(@as(u16, 1) << @intCast(second_len))));
                    buffer |= (self.buffer[byte_idx + 1] & mask) << @intCast(first_len);
                }
                return buffer;
            }

            const mask: u8 = @truncate(~(-%(@as(u16, 1) << @intCast(bits))));
            buffer |= (self.buffer[byte_idx] >> @intCast(bit_idx)) & mask;

            return buffer;
        }

        fn peek(self: *BitStream, bits: usize) !u16{
            if(bits <= 8) return try self.peek8(bits);

            const prev = self.bits_consumed;

            var buffer: u16 = try self.peek8(8);
            self.toss(8);
            buffer |= (@as(u16, try self.peek8(bits - 8))) << 8;

            self.bits_consumed = prev;

            return buffer;
        }

    fn toss(self: *BitStream, bits: usize) void{
        self.bits_consumed += bits;
    }
};

pub const DeflateHeaderBlock = packed struct {
    bfinal: u1 = 0, // last block?
    btype: u2 = 0, // 0 -> uncompressed, 1 -> fixed huffman codes, 2 -> custom huffman codes
};

const Symbol = struct{
    name: u15 = 0,
    code: u15 = 0,
    len: u4 = 0,
};



const end_of_block: u15 = 256;

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
        print("{}\n", .{h});
        var huffman_codes = HuffmanPrefixCodes{};

        if(h.bfinal == 1) {last = true; }

        if(h.btype == 0){}
        else if(h.btype == 2){
            huffman_codes = try readCustomHuffmanPrefixCodes(stream);   
        }
        
        var stop = false;

        while(!stop){
            const symbol = 
                try  decode(&huffman_codes.ll_symbols, huffman_codes.ll_count, stream);
        
            if(symbol < end_of_block){
                print("byte(curr byte => {}) {}\n", .{curr_byte, symbol});
                buffer[curr_byte] = @intCast(symbol);
                curr_byte += 1;
            }else if(symbol == end_of_block){
                stop = true;
                print("EOB\n", .{});
            }else {

                const length =  try decodeLength(symbol, stream);

                const d_symbol = 
                    try decode(&huffman_codes.d_symbols, huffman_codes.d_count, stream);

                const distance = try decodeDistance(d_symbol, stream);

                print("pair length({}) {}, distance({}) {}\n", .{symbol, length, d_symbol, distance});

                const start = curr_byte - distance;

                const end = start + length;

                const slice = buffer[start..end];

                @memmove(buffer[curr_byte..curr_byte+length], slice);

                curr_byte += length;
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

    for(0..hclen) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
        cl_symbols[i].name,
        cl_symbols[i].code,
        cl_symbols[i].len,
    });

    var h_codes = HuffmanPrefixCodes{
        .d_count = hdist + 1,
        .ll_count = hlit + 257,
    };

    var code_lengths: [317]u4 = @splat(0);
    var code_len: usize = 0;

    while(code_len < hlit+hdist+258){

        const code_symbol = try decode(&cl_symbols, hclen, stream);
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

    for(0..h_codes.ll_count) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
        h_codes.ll_symbols[i].name,
        h_codes.ll_symbols[i].code,
        h_codes.ll_symbols[i].len,
    });

    for(0..h_codes.d_count) |i| print("name -> {}, code -> {b}, len -> {}\n", .{
        h_codes.d_symbols[i].name,
        h_codes.d_symbols[i].code,
        h_codes.d_symbols[i].len,
    });

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


fn decode(symbols: []Symbol, n: u16, stream: *BitStream) !u15{
    for(0..n)|i|{
        if(symbols[i].len != 0 and 
            (reverse(symbols[i].len, try stream.peek(symbols[i].len)) == symbols[i].code)){
            stream.toss(symbols[i].len);
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

fn reverse(len: usize, bits: u16) u16{
    var i: usize = 0;
    var n: u16 = 0;

    while(i <= len - 1){
        const bit = @intFromBool((bits & (@as(u16, 1) << (@intCast(i)))) > 0);
        //std.debug.print("{}\n", .{len - i});
        n |= @as(u16, bit) << @intCast(len - i - 1);
        i += 1;
    }

    return n;
}

fn genHuffmanCodes(symbols: []Symbol, n: usize) void{
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
    var data: []u8 = &.{};
    
    while(true){
        var chunk = Chunk{};
        try readChunk(r, gpa, &chunk);
        defer gpa.free(chunk.data);
        
        if(mem.eql(u8, &chunk.type, "IEND")) break;
        if(mem.eql(u8, &chunk.type, "IDAT")){
            const tmp = try mem.concat(gpa, u8, &.{data, chunk.data});
            gpa.free(data);
            data = tmp;
        }
    }

    return data;
}

fn readChunk(r: *Io.Reader, allocator: Allocator, chunk: *Chunk) !void{
    chunk.len = try r.takeInt(u32, .big);
    
    if(chunk.len >= std.math.maxInt(u31) - 1) return error.ChunkTooLarge;

    try r.readSliceEndian(u8, &chunk.type, .big);
    chunk.data = try r.readAllocAll(allocator, chunk.len);
    errdefer allocator.free(chunk.data);
    
    try r.readSliceEndian(u8, &chunk.crc, .big);
}

fn readDeflateHeaderBlock(stream: *BitStream) !DeflateHeaderBlock{
    return @bitCast(@as(u3, @intCast(try stream.read(3))));
}

fn printBits(comptime T: type, num: T) void{
    const t = @typeInfo(T);
    const len = t.int.bits;

    if(is_little_endian){
        print("LSB\n|\nv\n", .{});
    }else{
        print("MSB\n|\nv\n", .{});
    }

    for(0..len) |i|{
        print("{}", .{(num >> @intCast(i)) & 1});
    }

    print("\n", .{});
}
