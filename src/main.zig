const std = @import("std");

const info = std.log.info;
const log = std.log.info;
const ArrayList = std.ArrayList;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator: *std.mem.Allocator = undefined;

const CLEAR_FROM_BEGINNING_SCREEN = "\x1b[1J";
const SET_CURSOR_POSITION_TOP = "\x1b[1;1H";

const MAX_LINE_LENGTH = 40;
const MAX_LINES_SOURCE = 30;

const LineType = enum { raw, parsed };
const LogLevel = enum { verbose };
const Line = struct {
    id: usize,
    kind: LineType,
    level: LogLevel,
    tag: [50]u8,
    content: [MAX_LINE_LENGTH]u8,

    fn info(self: *const Line) void {
        info("I:{}K:{}L:{}C:{s}", .{self.id, self.kind, self.level, self.content});
    }
};

const Device = struct {
    id: []u8,
    lines: []Line,
    end: usize,
    reader_thread: ?*std.Thread,
    pipelines: Pipeline,

    fn deinit(self: *const Device, alloc: anytype) void {
        alloc.free(self.lines);
    }
};

const UpdateType = enum { new_line, clear };
const Update = union(UpdateType) { new_line: u8, clear: f32};

//    var my_value = Tagged{ .b = 1.5 };
//    switch (my_value) {
//        .a => |*byte| byte.* += 1,
//        .b => |*float| float.* *= 2,
//        .c => |*b| b.* = !b.*,
//    }
//

const Pipeline = struct {
    queue: std.atomic.Queue(Update)
};


fn pipeline_reader(device: *Device) !void {
    var idx: usize = 0;
    while (true) : (idx += 1) {

    }
}

fn device_reader(device: *Device) !void {
    const args = &[_][]const u8{
        // "seq", "99999",
        "adb", "-s", device.*.id, "logcat", "-v", "time",
    };

    for (args) |arg| {
        info("reader: {s}", .{arg});
    }

    const r = try std.ChildProcess.init(args, allocator);
    r.stdout_behavior = std.ChildProcess.StdIo.Pipe;
    defer r.deinit();

    _ = try r.spawn();

    var out = r.stdout orelse return error.FailedToAcquireStdout;

    const stdout = std.io.getStdOut();

    const reader = out.reader();

    var buffer: [10000]u8 = undefined;
    var idx: usize = 0;
    while (true) : (idx += 1) {
        const read = try reader.readUntilDelimiterOrEof(&buffer, '\n'); // TODO Write directly to line.
        const content = read orelse break;

        if (idx >= MAX_LINES_SOURCE) {
            idx = 0;
            device.end = 0;

            try stdout.writeAll(CLEAR_FROM_BEGINNING_SCREEN);
            try stdout.writeAll(SET_CURSOR_POSITION_TOP); // FIXME: can be done in one call const c = a ** b
        }

        var line = &device.lines[idx];

        // TODO:
        // [ ] - Implement 'pipelines' (the thing that will filter all current lines according to a filter and output it somewhere) in this thread first. Make them async/move to other thread later.
        //      [ ] - Start by reading query from a file. Have a single file that read in loop where each line corresponds to a filter. Worry about exclusions later.
        //      [ ] - Write output to a file and close the file each time it's updated.
        // Notes:
        //
        // About avoiding copies of the original line: 
        // It's probably fine to make a copy of the line to the pipeline? The only case where more than one line arrives at the same time is when the filter changes and everything must be re-filtered
        // or when the device source lines fill the buffer and it has to be cleared. Is there any gain to be had by having more than one line available in the pipeline? or even avoiding the copy? SOA/AOS zig Vector stuff comes to mind but 
        // I don't think it would be practical? Gains around this can always be researched later.
        // Making a copy also makes passing the update to the threads that perform filtering easier? At least this breaks the dependency on Device struct, 
        // so the device may only copy to a queue and no knowledge of the current lines is required.
        //
        // About the mechanism of clearing lines when there's no space: 
        // There's probably no need to clear all lines when the buffer fills and in fact it would make sense to rotate the lines around, but do we gain anything by clearing the oldest line?
        // I think this would require that all the remaining lines would be shifted to the previous position and this involves extra work. Is there any clever workaround?
        // The 'pipelines' don't really care for lines that we no longer have space for, so it should be ok to just message the pipelines that the lines were cleared and re-filter line by line.


        line.id = idx;
        const min_len = std.math.min(MAX_LINE_LENGTH, content.len);
        std.mem.copy(u8, &line.content, content[0..min_len]);

        line.info();
    }

    info("exiting reader: {s}", .{device.id});
}

pub fn main() anyerror!void {
    allocator = &gpa.allocator;
    defer {
        const leaked = gpa.deinit();
        std.debug.assert(!leaked);
    }

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable path
    _ = args.skip();

    var device_ids = ArrayList([]u8).init(allocator);
    defer device_ids.deinit();

    while (true) {
        var arg = args.next(allocator) orelse break;
        info("device_id={s}", .{arg});

        var id = arg catch break;
        try device_ids.append(id);
    }

    defer {
        for (device_ids.items) |id| {
            allocator.free(id);
        }
    }

    if (device_ids.items.len == 0) {
        info("You have to provide the devices ids", .{});
        return;
    }

    var devices = std.ArrayList(Device).init(allocator);
    defer {
        for (devices.items) |d| {
            d.deinit(allocator);
        }
        devices.deinit();
    }

    for (device_ids.items) |id, idx| {
        info("creating device: {s} {}", .{id, idx});    

        var pipeline = Pipeline {
            .queue = std.atomic.Queue(Update).init(),
        };

        var device = Device{
            .id = id,
            .end = 0,
            .lines = try allocator.alloc(Line, MAX_LINES_SOURCE),
            .reader_thread = null,
            .pipelines = pipeline
        };

        device.reader_thread = try std.Thread.spawn(device_reader, &device);

        try devices.append(device);
    }

    for (devices.items) |device| {
        var thread = device.reader_thread orelse continue;
        info("waiting for thread", .{});    
        thread.wait();
    }
    
    //data = std.StringHashMap(*std.ArrayList([]u8)).init(allocator);
    //var device_data = std.ArrayList([]u8).init(allocator);
    //defer device_data.deinit();
    //defer data.deinit();

    //const reader_thread = try std.Thread.spawn(reader, {});
    //reader_thread.wait();
    
    info("exiting", .{});
}
