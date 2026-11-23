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

    var t = Io.Clock.awake.now(io);

    var image = try moo_image.png.load(path, gpa, io);
    defer image.free(gpa);

    std.debug.print("{}ms\n", .{t.untilNow(io, .awake).toMilliseconds()});

    var test_buff: [1024]u8 = undefined;
    var f2 = try Io.Dir.cwd().createFile(init.io, "image_test/test.ppm", .{});
    defer f2.close(init.io);
    var fw = f2.writer(init.io, &test_buff);
    var w = &fw.interface;
    try w.print("P6\n{} {}\n255\n", .{image.width, image.height});
    _ = try w.write(image.data);
}
