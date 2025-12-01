const std = @import("std");
const linux = std.os.linux;
const print = std.debug.print;

const PerfCounter = struct {
    fd: i32,

    pub fn init() !PerfCounter {
        var attr = std.mem.zeroes(linux.perf_event_attr);
        attr.type = linux.PERF.TYPE.HARDWARE;
        attr.config = @intFromEnum(linux.PERF.COUNT.HW.BRANCH_MISSES);
        attr.flags.disabled = true;
        attr.flags.exclude_kernel = true;
        attr.flags.exclude_hv = true;
        attr.flags.exclude_idle = true;

        const rc = linux.perf_event_open(&attr, 0, -1, -1, 0);
        if (@as(isize, @bitCast(rc)) < 0) {
            return error.PerfEventOpenFailed;
        }
        return .{ .fd = @intCast(rc) };
    }

    pub fn reset(self: PerfCounter) void {
        _ = linux.ioctl(self.fd, linux.PERF.EVENT_IOC.RESET, 0);
    }

    pub fn enable(self: PerfCounter) void {
        _ = linux.ioctl(self.fd, linux.PERF.EVENT_IOC.ENABLE, 0);
    }

    pub fn disable(self: PerfCounter) void {
        _ = linux.ioctl(self.fd, linux.PERF.EVENT_IOC.DISABLE, 0);
    }

    pub fn read(self: PerfCounter) f64 {
        var buffer: [8]u8 = undefined;
        const amount = linux.read(self.fd, &buffer, buffer.len);
        std.debug.assert(amount == buffer.len);

        const value = std.mem.readInt(u64, &buffer, .little);
        return @floatFromInt(value);
    }

    pub fn deinit(self: PerfCounter) void {
        _ = linux.close(self.fd);
    }
};

noinline fn call_chain(depth: usize) void {
    if (depth > 1) call_chain(depth - 1);
}

pub fn main() !void {
    const counter = PerfCounter.init() catch |err| {
        print("Error: {s}\n", .{@errorName(err)});
        print("Run with: sudo or set /proc/sys/kernel/perf_event_paranoid to <= 2\n", .{});
        return;
    };
    defer counter.deinit();

    const iterations: usize = 100000;
    var previous_misses_average: f64 = 0;

    // NOTE: warmup for more predictable results.
    for (0..1000) |_| call_chain(32);

    for (1..92 + 1) |depth| {
        counter.reset();

        counter.enable();
        for (0..iterations) |_| call_chain(depth);
        counter.disable();

        const floating_iterations = @as(f64, @floatFromInt(iterations));

        const misses_total = counter.read();
        const misses_average = misses_total / floating_iterations;
        const misses_delta = misses_average - previous_misses_average;

        print("depth={d},misses_average={d:.3},delta_ns={d:.8}\n", .{ depth, misses_average, misses_delta });

        previous_misses_average = misses_average;

        if (misses_average > 0.9) {
            std.debug.print("ras_size={d}", .{depth});
            break;
        }
    }
}
