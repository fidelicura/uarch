const std = @import("std");
const linux = std.os.linux;

const task_type = *const volatile fn (usize) callconv(.c) void;
const task_ptr: task_type = @ptrCast(&task);

noinline fn task(depth: usize) callconv(.c) void {
    if (depth > 1) @call(.never_tail, &task, .{depth - 1});
}

const BenchResult = struct {
    average_branch_instructions: f64,
    average_branch_misses: f64,
    average_miss_rate: f64,
    average_ras_misses: f64,
};

fn runBench(
    task_queue: []task_type,
    call_depth: usize,
    try_count: usize,
    fd_branches: linux.fd_t,
    fd_misses: linux.fd_t,
    fd_ras: linux.fd_t,
) BenchResult {
    var return_value: usize = 0;

    // STEP: warmup before benchmarking.

    for (task_queue) |task_entry| @call(.never_tail, task_entry, .{call_depth});

    // STEP: start tasks benchmarking.

    var average_branch_instructions: f64 = 0.0;
    var average_branch_misses: f64 = 0.0;
    var average_ras_misses: f64 = 0.0;

    std.debug.print("try_number,total_branches,branch_misses,miss_rate,ras_misses\n", .{});
    for (1..try_count + 1) |try_number| {
        // STEP: reset perf metrics.

        return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.RESET, linux.PERF.IOC_FLAG_GROUP);
        std.debug.assert(return_value == 0);

        // STEP: enable perf metrics.

        return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.ENABLE, linux.PERF.IOC_FLAG_GROUP);
        std.debug.assert(return_value == 0);

        // STEP: perform tasks benchmarking.

        for (task_queue) |task_entry| @call(.never_tail, task_entry, .{call_depth});

        // STEP: disable perf metrics.

        return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.DISABLE, linux.PERF.IOC_FLAG_GROUP);
        std.debug.assert(return_value == 0);

        // STEP: parse perf metrics.

        var branch_instructions: usize = 0;
        var branch_misses: usize = 0;
        var ras_misses: usize = 0;

        return_value = linux.read(@intCast(fd_branches), std.mem.asBytes(&branch_instructions), @sizeOf(usize));
        std.debug.assert(return_value == @sizeOf(usize));
        return_value = linux.read(@intCast(fd_misses), std.mem.asBytes(&branch_misses), @sizeOf(usize));
        std.debug.assert(return_value == @sizeOf(usize));
        return_value = linux.read(@intCast(fd_ras), std.mem.asBytes(&ras_misses), @sizeOf(usize));
        std.debug.assert(return_value == @sizeOf(usize));

        // STEP: calculate rate metrics.

        const count_branches: f64 = @floatFromInt(branch_instructions);
        const count_misses: f64 = @floatFromInt(branch_misses);
        const miss_rate = count_misses / count_branches * 100.0;

        // STEP: print benchmarking results.

        std.debug.print(
            "{d},{d},{d},{d:.2},{d}\n",
            .{ try_number, branch_instructions, branch_misses, miss_rate, ras_misses },
        );

        // STEP: include average metrics.

        average_branch_instructions += @floatFromInt(branch_instructions);
        average_branch_misses += @floatFromInt(branch_misses);
        average_ras_misses += @floatFromInt(ras_misses);
    }

    average_branch_instructions /= @floatFromInt(try_count);
    average_branch_misses /= @floatFromInt(try_count);
    average_ras_misses /= @floatFromInt(try_count);
    const average_miss_rate = average_branch_misses / average_branch_instructions * 100.0;

    return .{
        .average_branch_instructions = average_branch_instructions,
        .average_branch_misses = average_branch_misses,
        .average_miss_rate = average_miss_rate,
        .average_ras_misses = average_ras_misses,
    };
}

pub fn main(init: std.process.Init) !void {
    var return_value: usize = 0;

    // STEP: setup allocator facility.

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = false }).init;
    const allocator = gpa.allocator();

    // STEP: handle program arguments.

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len != 5) {
        std.debug.print("Usage: {s} <try_count> <depth_a> <depth_b> <call_amount>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const try_count = try std.fmt.parseInt(usize, args[1], 10);
    const depth_a = try std.fmt.parseInt(usize, args[2], 10);
    const depth_b = try std.fmt.parseInt(usize, args[3], 10);
    const call_amount = try std.fmt.parseInt(usize, args[4], 10);

    // STEP: setup task queue.

    const task_queue = try allocator.alloc(task_type, call_amount);
    defer allocator.free(task_queue);

    for (task_queue) |*task_entry| task_entry.* = task_ptr;

    // STEP: setup perf events.

    var branches_event = linux.perf_event_attr{
        .type = .HARDWARE,
        .config = @intFromEnum(linux.PERF.COUNT.HW.BRANCH_INSTRUCTIONS),
        .flags = .{ .exclude_kernel = true, .exclude_hv = true },
    };
    var misses_event = linux.perf_event_attr{
        .type = .HARDWARE,
        .config = @intFromEnum(linux.PERF.COUNT.HW.BRANCH_MISSES),
        .flags = .{ .exclude_kernel = true, .exclude_hv = true },
    };
    var ras_event = linux.perf_event_attr{
        .type = .RAW,
        .config = 0xC9, // <https://github.com/torvalds/linux/blob/v6.17-rc7/tools/perf/pmu-events/arch/x86/amdzen4/branch.json#L47-L51>
        .flags = .{ .exclude_kernel = true, .exclude_hv = true },
    };

    // STEP: setup perf descriptors.

    const fd_branches: linux.fd_t = @intCast(linux.perf_event_open(&branches_event, 0, -1, -1, 0));
    std.debug.assert(fd_branches >= 0);
    const fd_misses: linux.fd_t = @intCast(linux.perf_event_open(&misses_event, 0, -1, fd_branches, 0));
    std.debug.assert(fd_misses >= 0);
    const fd_ras: linux.fd_t = @intCast(linux.perf_event_open(&ras_event, 0, -1, fd_branches, 0));
    std.debug.assert(fd_ras >= 0);

    // STEP: disable perf temporarily.

    return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.DISABLE, linux.PERF.IOC_FLAG_GROUP);
    std.debug.assert(return_value == 0);

    // STEP: lock address space.

    return_value = linux.mlockall(.{ .CURRENT = true, .FUTURE = true });
    std.debug.assert(return_value == 0);

    // STEP: benchmark depth A.

    std.debug.print("--- depth = {d} ---\n", .{depth_a});
    const result_a = runBench(task_queue, depth_a, try_count, fd_branches, fd_misses, fd_ras);

    // STEP: benchmark depth B.

    std.debug.print("\n--- depth = {d} ---\n", .{depth_b});
    const result_b = runBench(task_queue, depth_b, try_count, fd_branches, fd_misses, fd_ras);

    // STEP: print comparison summary.

    std.debug.print(
        \\--- summary ---
        \\depth={d:<10} avg_branches={d:<16.2} avg_misses={d:<12.2} avg_miss_rate=%{d:<8.2} avg_ras_misses={d:.2}
        \\depth={d:<10} avg_branches={d:<16.2} avg_misses={d:<12.2} avg_miss_rate=%{d:<8.2} avg_ras_misses={d:.2}
        \\
    , .{
        depth_a, result_a.average_branch_instructions, result_a.average_branch_misses, result_a.average_miss_rate, result_a.average_ras_misses,
        depth_b, result_b.average_branch_instructions, result_b.average_branch_misses, result_b.average_miss_rate, result_b.average_ras_misses,
    });

    const call_amount_f: f64 = @floatFromInt(call_amount);
    const threshold = 0.001; // = 0.1%
    const overflow_a = result_a.average_ras_misses / call_amount_f > threshold;
    const overflow_b = result_b.average_ras_misses / call_amount_f > threshold;

    if (!overflow_a and overflow_b) {
        std.debug.print("RAS overflow detected between depth {d} and {d}\n", .{ depth_a, depth_b });
    } else if (overflow_a and !overflow_b) {
        std.debug.print("RAS overflow detected between depth {d} and {d}\n", .{ depth_b, depth_a });
    } else if (!overflow_a and !overflow_b) {
        std.debug.print("No RAS overflow detected at either depth\n", .{});
    } else {
        std.debug.print("RAS overflow detected at both depths\n", .{});
    }
}
