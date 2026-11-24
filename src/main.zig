const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

const moo_image = @import("moo_image.zig");


pub fn main(init: std.process.Init) !void{
    const io = init.io;
    const gpa = init.gpa;
    const path: []const u8 = "image_test/file_example_PNG_500kB.png";

    var t1 = Io.Clock.awake.now(io);

    var image1 = try moo_image.png.load(path, gpa, io);
    defer image1.free(gpa);

    std.debug.print("first {}ms\n", .{t1.untilNow(io, .awake).toMilliseconds()});

    var average: f64 = 0;
    var tot: i96 = 0;

    for(0..40) |i|{
        std.debug.print("TEST CASE {}\n\n", .{i});
        var t = Io.Clock.awake.now(io);

        var image = try moo_image.png.load(path, gpa, io);
        defer image.free(gpa);

        const time = t.untilNow(io, .awake).toNanoseconds();
        tot += time;

        std.debug.print("{} ms\n", 
            .{@as(f64, @floatFromInt(@as(i64, @truncate(time)))) / 1000000});
        
        std.debug.print("_____________\n\n", .{});
    }

    average = (@as(f64, @floatFromInt(@as(i64, @truncate(tot)))) / 40) / 1000000;

    std.debug.print("average {} ms\n", .{average});

    var test_buff: [1024]u8 = undefined;
    var f2 = try Io.Dir.cwd().createFile(init.io, "image_test/test.ppm", .{});
    defer f2.close(init.io);
    var fw = f2.writer(init.io, &test_buff);
    var w = &fw.interface;
    try w.print("P6\n{} {}\n255\n", .{image1.width, image1.height});
    _ = try w.write(image1.data);
}
