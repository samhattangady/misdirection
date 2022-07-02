const std = @import("std");
const c = @import("platform.zig");
const constants = @import("constants.zig");

const glyph_lib = @import("glyphee.zig");
const TypeSetter = glyph_lib.TypeSetter;

const helpers = @import("helpers.zig");
const Vector2 = helpers.Vector2;
const Camera = helpers.Camera;
const SingleInput = helpers.SingleInput;
const MouseState = helpers.MouseState;
const EditableText = helpers.EditableText;
const TYPING_BUFFER_SIZE = 16;
const PATH_SPACING = 10;
const PATH_SPACING_SQR = PATH_SPACING * PATH_SPACING;
const SELECTION_BUFFER = 48;
const SELECTION_BUFFER_SQR = SELECTION_BUFFER * SELECTION_BUFFER;

const InputKey = enum {
    shift,
    tab,
    enter,
    space,
    escape,
    ctrl,
};
const WebInputMap = struct {
    key: c_uint,
    input: InputKey,
};
const WEB_INPUT_MAPPING = [_]WebInputMap{
    .{ .key = 27, .input = .escape },
    .{ .key = 32, .input = .space },
};
const INPUT_KEYS_COUNT = @typeInfo(InputKey).Enum.fields.len;
const InputMap = struct {
    key: c.SDL_Keycode,
    input: InputKey,
};

const INPUT_MAPPING = [_]InputMap{
    .{ .key = c.SDLK_LSHIFT, .input = .shift },
    .{ .key = c.SDLK_LCTRL, .input = .ctrl },
    .{ .key = c.SDLK_TAB, .input = .tab },
    .{ .key = c.SDLK_RETURN, .input = .enter },
    .{ .key = c.SDLK_SPACE, .input = .space },
    .{ .key = c.SDLK_ESCAPE, .input = .escape },
};

pub const InputState = struct {
    const Self = @This();
    keys: [INPUT_KEYS_COUNT]SingleInput = [_]SingleInput{.{}} ** INPUT_KEYS_COUNT,
    mouse: MouseState = MouseState{},
    typed: [TYPING_BUFFER_SIZE]u8 = [_]u8{0} ** TYPING_BUFFER_SIZE,
    num_typed: usize = 0,

    pub fn get_key(self: *Self, key: InputKey) *SingleInput {
        return &self.keys[@enumToInt(key)];
    }

    pub fn type_key(self: *Self, k: u8) void {
        if (self.num_typed >= TYPING_BUFFER_SIZE) {
            helpers.debug_print("Typing buffer already filled.\n", .{});
            return;
        }
        self.typed[self.num_typed] = k;
        self.num_typed += 1;
    }

    pub fn reset(self: *Self) void {
        for (self.keys) |*key| key.reset();
        self.mouse.reset_mouse();
        self.num_typed = 0;
    }
};

const PointDistance = struct {
    index: usize,
    distance: f32,
};

pub const Path = struct {
    const Self = @This();
    points: std.ArrayList(Vector2),
    max_points: usize = 500,
    allocator: std.mem.Allocator,
    is_active: bool = false,
    is_selectable: bool = false,
    delete_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .points = std.ArrayList(Vector2).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.points.deinit();
    }

    pub fn update(self: *Self, mouse: *MouseState) void {
        const closest = self.closest_point_distance(mouse.current_pos);
        if (closest.distance < SELECTION_BUFFER_SQR) {
            self.delete_index = closest.index;
        } else {
            self.delete_index = null;
        }
        self.is_selectable = self.in_selection_buffer(mouse.current_pos);
        if (mouse.l_button.is_clicked) {
            self.is_active = self.is_selectable;
            self.is_selectable = false;
            self.delete_index = null;
        }
        if (mouse.l_button.is_down and self.is_active) {
            self.try_add_point(mouse.current_pos);
            self.is_selectable = false;
            self.delete_index = null;
        }
        if (self.is_selectable) self.delete_index = null;
        if (mouse.r_button.is_clicked) {
            if (self.delete_index) |di| {
                self.points.shrinkRetainingCapacity(di + 1);
            }
        }
    }

    /// All the points in the path have a certain spacing / distance between them
    /// Let dist be the distance between pos and the last point.
    /// If the distance is more than SPACING, we find the closest point in the direction
    /// If the distance is less than SPACING, we do nothing
    // TODO (02 Jul 2022 sam): Should this return ?Vector2
    pub fn try_add_point(self: *Self, pos: Vector2) void {
        if (self.points.items.len == 0) {
            self.points.append(pos) catch unreachable;
            return;
        }
        if (self.points.items.len >= self.max_points) return;
        const last = self.points.items[self.points.items.len - 1];
        const dist_sqr = pos.distance_to_sqr(last);
        if (dist_sqr < PATH_SPACING_SQR) return;
        const dist = @sqrt(dist_sqr);
        const amount = PATH_SPACING / dist;
        helpers.debug_print("dist = {d}\n, SPACING = {d}, amount = {d}\n", .{ dist, PATH_SPACING, amount });
        const point = last.lerped(pos, amount);
        self.points.append(point) catch unreachable;
    }

    pub fn fract_used(self: *const Self) f32 {
        return @intToFloat(f32, self.points.items.len) / @intToFloat(f32, self.max_points);
    }

    pub fn in_selection_buffer(self: *Self, pos: Vector2) bool {
        std.debug.assert(self.points.items.len > 0);
        const last = self.points.items[self.points.items.len - 1];
        const dist_sqr = pos.distance_to_sqr(last);
        return dist_sqr < SELECTION_BUFFER_SQR;
    }

    pub fn selectable_pos(self: *const Self) ?Vector2 {
        if (!self.is_selectable) return null;
        return self.points.items[self.points.items.len - 1];
    }

    pub fn delete_pos(self: *const Self) ?Vector2 {
        if (self.delete_index == null) return null;
        return self.points.items[self.delete_index.?];
    }

    fn closest_point_distance(self: *const Self, pos: Vector2) PointDistance {
        var pd = PointDistance{
            .index = 0,
            .distance = self.points.items[0].distance_to_sqr(pos),
        };
        for (self.points.items) |point, i| {
            if (i == 0) continue;
            const dsqr = point.distance_to_sqr(pos);
            if (dsqr < pd.distance) {
                pd.distance = dsqr;
                pd.index = i;
            }
        }
        return pd;
    }
};

pub const Magician = struct {
    const Self = @This();
    position: Vector2 = .{ .x = 300, .y = 500 },
    size: Vector2 = .{ .x = 60, .y = 96 },
    path: Path,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .path = Path.init(allocator),
            .allocator = allocator,
        };
        self.path.try_add_point(self.position);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.path.deinit();
    }
};

pub const App = struct {
    const Self = @This();
    typesetter: TypeSetter = undefined,
    camera: Camera = .{},
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    ticks: u32 = 0,
    quit: bool = false,
    inputs: InputState = .{},
    magician: Magician,
    active_path: ?*Path = null,
    load_data: []u8 = undefined,
    selectable_pos: ?Vector2 = null,
    delete_pos: ?Vector2 = null,

    pub fn new(allocator: std.mem.Allocator, arena: std.mem.Allocator) Self {
        return Self{
            .magician = Magician.init(allocator),
            .allocator = allocator,
            .arena = arena,
        };
    }

    pub fn init(self: *Self) !void {
        try self.typesetter.init(&self.camera, self.allocator);
    }

    pub fn deinit(self: *Self) void {
        self.typesetter.deinit();
        self.magician.deinit();
    }

    pub fn handle_inputs(self: *Self, event: c.SDL_Event) void {
        if (event.@"type" == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_END)
            self.quit = true;
        self.inputs.mouse.handle_input(event, self.ticks, &self.camera);
        if (event.@"type" == c.SDL_KEYDOWN) {
            for (INPUT_MAPPING) |map| {
                if (event.key.keysym.sym == map.key) self.inputs.get_key(map.input).set_down(self.ticks);
            }
        } else if (event.@"type" == c.SDL_KEYUP) {
            for (INPUT_MAPPING) |map| {
                if (event.key.keysym.sym == map.key) self.inputs.get_key(map.input).set_release();
            }
        }
    }

    pub fn web_handle_key_inputs(self: *Self, down: bool, event_code: c_uint) void {
        if (!constants.WEB_BUILD) return;
        if (down) {
            for (WEB_INPUT_MAPPING) |map| {
                if (event_code == map.key) self.inputs.get_key(map.input).set_down(self.ticks);
            }
        } else {
            for (WEB_INPUT_MAPPING) |map| {
                if (event_code == map.key) self.inputs.get_key(map.input).set_release();
            }
        }
    }

    pub fn update(self: *Self, ticks: u32, arena: std.mem.Allocator) void {
        self.ticks = ticks;
        self.arena = arena;
        self.magician.path.update(&self.inputs.mouse);
    }

    pub fn end_frame(self: *Self) void {
        self.inputs.reset();
    }
};
