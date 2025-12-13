const std = @import("std");
const linux = std.os.linux;

const task_type = *const volatile fn (usize) callconv(.c) void;
const task_ptr: task_type = @ptrCast(&task);

// noinline fn task(depth: usize) callconv(.c) void {
//     // asm volatile (
//     //     \\ testq %%rdi, %%rdi
//     //     \\ je 1f
//     //     \\ pushq %%rax
//     //     \\ decq %%rdi
//     //     \\ callq main.task
//     //     \\ addq $8, %%rsp
//     //     \\ 1:
//     //     :
//     //     : [depth] "{rdi}" (depth),
//     //     : .{ .rax = true });

//     // asm volatile (
//     //     \\ testq %%rdi, %%rdi
//     //     \\ je 3f
//     //     \\ pushq %%rax
//     //     \\ decq %%rdi
//     //     \\ testq $1, %%rdi
//     //     \\ jz 1f
//     //     \\ callq main.task
//     //     \\ jmp 2f
//     //     \\ 1: callq main.task
//     //     \\ 2: addq $8, %%rsp
//     //     \\ 3:
//     //     :
//     //     : [depth] "{rdi}" (depth),
//     //     : .{ .rax = true });
// }

noinline fn task(depth: usize) callconv(.c) void {
    if (depth > 1) @call(.never_tail, &task, .{depth - 1});
}

pub fn main() !void {
    var return_value: usize = 0;

    // STEP: setup allocator facility.

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = false }).init;
    const allocator = gpa.allocator();

    // STEP: handle program arguments.

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 4) {
        std.debug.print("Usage: {s} <used_core> <call_depth> <call_amount>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const used_core = try std.fmt.parseInt(i32, args[1], 10);
    const call_depth = try std.fmt.parseInt(usize, args[2], 10);
    const call_amount = try std.fmt.parseInt(usize, args[3], 10);

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
    var btb_event = linux.perf_event_attr{
        .type = .RAW,
        .config = 0x91, // <https://github.com/torvalds/linux/blob/v6.17-rc7/tools/perf/pmu-events/arch/x86/amdzen4/branch.json#L12-L16>
        .flags = .{ .exclude_kernel = true, .exclude_hv = true },
    };

    // STEP: setup perf descriptors.

    const fd_branches: linux.fd_t = @intCast(linux.perf_event_open(&branches_event, 0, used_core, -1, linux.PERF.FLAG.FD_NO_GROUP));
    std.debug.assert(fd_branches >= 0);
    const fd_misses: linux.fd_t = @intCast(linux.perf_event_open(&misses_event, 0, used_core, -1, linux.PERF.FLAG.FD_NO_GROUP));
    std.debug.assert(fd_misses >= 0);
    const fd_ras: linux.fd_t = @intCast(linux.perf_event_open(&ras_event, 0, used_core, -1, linux.PERF.FLAG.FD_NO_GROUP));
    std.debug.assert(fd_misses >= 0);
    const fd_btb: linux.fd_t = @intCast(linux.perf_event_open(&btb_event, 0, used_core, -1, linux.PERF.FLAG.FD_NO_GROUP));
    std.debug.assert(fd_misses >= 0);

    // STEP: reset perf metrics.

    return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.RESET, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_misses, linux.PERF.EVENT_IOC.RESET, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_ras, linux.PERF.EVENT_IOC.RESET, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_btb, linux.PERF.EVENT_IOC.RESET, 0);
    std.debug.assert(return_value == 0);

    // STEP: disable perf temporarily.

    return_value = linux.ioctl(fd_misses, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_ras, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_btb, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);

    // STEP: lock address space.

    return_value = linux.mlockall(.{ .CURRENT = true, .FUTURE = true });
    std.debug.assert(return_value == 0);

    // STEP: warmup before benchmarking.

    for (task_queue) |task_entry| @call(.never_tail, task_entry, .{call_depth});

    // STEP: enable perf metrics.

    return_value = linux.ioctl(fd_misses, linux.PERF.EVENT_IOC.ENABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.ENABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_ras, linux.PERF.EVENT_IOC.ENABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_btb, linux.PERF.EVENT_IOC.ENABLE, 0);
    std.debug.assert(return_value == 0);

    // STEP: perform tasks benchmarking.

    for (task_queue) |task_entry| @call(.never_tail, task_entry, .{call_depth});

    // STEP: disable perf metrics.

    return_value = linux.ioctl(fd_misses, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_branches, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_ras, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);
    return_value = linux.ioctl(fd_btb, linux.PERF.EVENT_IOC.DISABLE, 0);
    std.debug.assert(return_value == 0);

    // STEP: parse perf metrics.

    var branch_instructions: usize = 0;
    var branch_misses: usize = 0;
    var ras_misses: usize = 0;
    var btb_misses: usize = 0;

    return_value = linux.read(@intCast(fd_branches), std.mem.asBytes(&branch_instructions), @sizeOf(usize));
    std.debug.assert(return_value <= @sizeOf(usize));
    return_value = linux.read(@intCast(fd_misses), std.mem.asBytes(&branch_misses), @sizeOf(usize));
    std.debug.assert(return_value <= @sizeOf(usize));
    return_value = linux.read(@intCast(fd_ras), std.mem.asBytes(&ras_misses), @sizeOf(usize));
    std.debug.assert(return_value <= @sizeOf(usize));
    return_value = linux.read(@intCast(fd_btb), std.mem.asBytes(&btb_misses), @sizeOf(usize));
    std.debug.assert(return_value <= @sizeOf(usize));

    // STEP: calculate rate metrics.

    const count_branches: f64 = @floatFromInt(branch_instructions);
    const count_misses: f64 = @floatFromInt(branch_misses);
    const miss_rate = count_misses / count_branches * 100.0;

    // STEP: print benchmarking results.

    std.debug.print(
        "branches: {d}, missed: {d}, rate: {d:.2}, RAS missed: {d}, BTB missed: {d}\n",
        .{ branch_instructions, branch_misses, miss_rate, ras_misses, btb_misses },
    );
}
