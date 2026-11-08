const std = @import("std");
const Io = std.Io;
const moo_image = @import("moo_image.zig");



pub fn main(init: std.process.Init) !void{
    const path = "image_test/file_example_PNG_500kB.png";
    var img = try moo_image.loadPng(path, init.io, init.gpa);
    defer img.free(init.gpa);


    var test_buff: [1024]u8 = undefined;
    var tf = try Io.Dir.cwd().createFile(init.io, "image_test/test.ppm", .{});
    defer tf.close(init.io);
    var tfw = tf.writer(init.io, &test_buff);
    var tfwi = &tfw.interface;
    try tfwi.print("P6\n{} {}\n255\n", .{img.width, img.height});
    _ = try tfwi.write(img.buffer);
}