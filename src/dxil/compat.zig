const std = @import("std");

pub const ClipOrigin = enum(u32) { lower_left, upper_left };
pub const ClipDepth = enum(u32) { negative_one_to_one, zero_to_one };
pub const Winding = enum(u32) { ccw, cw };
pub const State = struct {
    clip_origin: ClipOrigin = .lower_left,
    clip_depth: ClipDepth = .negative_one_to_one,
    winding: Winding = .ccw,
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_width: f32,
    viewport_height: f32,
    target_height: f32,
    depth_near: f32 = 0,
    depth_far: f32 = 1,
    base_instance: u32 = 0,
};
pub const Prepared = struct {
    constants: [8]u32,
    viewport: [6]f32,
    front_counter_clockwise: bool,
    start_instance_location: u32,
};

pub fn prepare(state: State) error{InvalidArgument}!Prepared {
    for ([_]f32{ state.viewport_x, state.viewport_y, state.viewport_width, state.viewport_height, state.target_height, state.depth_near, state.depth_far }) |number| if (!std.math.isFinite(number)) return error.InvalidArgument;
    if (state.viewport_width <= 0 or state.viewport_height <= 0 or state.target_height <= 0 or state.viewport_x < 0 or state.viewport_y < 0 or state.viewport_y + state.viewport_height > state.target_height or state.depth_near < 0 or state.depth_near > 1 or state.depth_far < 0 or state.depth_far > 1) return error.InvalidArgument;
    const reverse = state.depth_near > state.depth_far;
    const negative = state.clip_depth == .negative_one_to_one;
    const depth_scale: f32 = if (reverse) (if (negative) -0.5 else -1) else (if (negative) 0.5 else 1);
    const depth_bias: f32 = if (negative) 0.5 else if (reverse) 1 else 0;
    return .{
        .constants = .{ @bitCast(@as(f32, if (state.clip_origin == .lower_left) 1 else -1)), @bitCast(depth_scale), @bitCast(depth_bias), @bitCast(state.target_height), 0, 0, 0, 0 },
        .viewport = .{ state.viewport_x, state.target_height - state.viewport_y - state.viewport_height, state.viewport_width, state.viewport_height, @min(state.depth_near, state.depth_far), @max(state.depth_near, state.depth_far) },
        .front_counter_clockwise = (state.clip_origin == .lower_left) != (state.winding == .cw),
        .start_instance_location = state.base_instance,
    };
}

test "OpenGL compatibility states preserve clipping and separate viewport depth range" {
    for ([_]ClipOrigin{ .lower_left, .upper_left }) |origin| for ([_]ClipDepth{ .negative_one_to_one, .zero_to_one }) |depth| for ([_][2]f32{ .{ 0, 1 }, .{ 0.2, 0.8 }, .{ 0.8, 0.2 } }) |range| {
        const result = try prepare(.{ .clip_origin = origin, .clip_depth = depth, .viewport_x = 2, .viewport_y = 3, .viewport_width = 8, .viewport_height = 4, .target_height = 16, .depth_near = range[0], .depth_far = range[1], .base_instance = 7 });
        try std.testing.expectEqual(@as(f32, 9), result.viewport[1]);
        try std.testing.expectEqual(@as(u32, 7), result.start_instance_location);
        try std.testing.expectEqual(@as(u32, 0), result.constants[4]);
        const scale: f32 = @bitCast(result.constants[1]);
        const bias: f32 = @bitCast(result.constants[2]);
        const near_clip: f32 = if (depth == .negative_one_to_one) -1 else 0;
        const window_near = (near_clip * scale + bias) * (result.viewport[5] - result.viewport[4]) + result.viewport[4];
        const window_far = (scale + bias) * (result.viewport[5] - result.viewport[4]) + result.viewport[4];
        try std.testing.expectApproxEqAbs(range[0], window_near, 0.000001);
        try std.testing.expectApproxEqAbs(range[1], window_far, 0.000001);
    };
    try std.testing.expectError(error.InvalidArgument, prepare(.{ .viewport_width = 1, .viewport_height = 0, .target_height = 1 }));
}

test "GL state rejects invalid and nonfinite viewport and depth values" {
    const valid: State = .{ .viewport_width = 4, .viewport_height = 4, .target_height = 8 };
    const invalid_states = [_]State{
        .{ .viewport_width = std.math.nan(f32), .viewport_height = 4, .target_height = 8 },
        .{ .viewport_width = 4, .viewport_height = 4, .target_height = std.math.inf(f32) },
        .{ .viewport_x = -1, .viewport_width = 4, .viewport_height = 4, .target_height = 8 },
        .{ .viewport_y = 6, .viewport_width = 4, .viewport_height = 4, .target_height = 8 },
        .{ .viewport_width = 4, .viewport_height = 4, .target_height = 8, .depth_near = -0.1 },
        .{ .viewport_width = 4, .viewport_height = 4, .target_height = 8, .depth_far = 1.1 },
        .{ .viewport_width = 4, .viewport_height = 4, .target_height = 8, .depth_near = std.math.nan(f32) },
    };
    _ = try prepare(valid);
    for (invalid_states) |state| try std.testing.expectError(error.InvalidArgument, prepare(state));
    for ([_]ClipOrigin{ .lower_left, .upper_left }) |origin| for ([_]Winding{ .ccw, .cw }) |winding| {
        var state = valid;
        state.clip_origin = origin;
        state.winding = winding;
        try std.testing.expectEqual((origin == .lower_left) != (winding == .cw), (try prepare(state)).front_counter_clockwise);
    };
}
