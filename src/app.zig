const std = @import("std");
const c = @import("platform.zig");
const constants = @import("constants.zig");

const glyph_lib = @import("glyphee.zig");
const TypeSetter = glyph_lib.TypeSetter;

const helpers = @import("helpers.zig");
const Vector2 = helpers.Vector2;
const Vector4_gl = helpers.Vector4_gl;
const Camera = helpers.Camera;
const SingleInput = helpers.SingleInput;
const MouseState = helpers.MouseState;
const EditableText = helpers.EditableText;
const TYPING_BUFFER_SIZE = 16;
const PATH_SPACING = 10;
const PATH_SPACING_SQR = PATH_SPACING * PATH_SPACING;
const SELECTION_BUFFER = 48;
const SELECTION_BUFFER_SQR = SELECTION_BUFFER * SELECTION_BUFFER;
const magician_color = Vector4_gl{ .x = 0.5, .y = 0.5, .z = 0.9, .w = 1.0 };
const assistant_color = Vector4_gl{ .x = 0.5, .y = 0.9, .z = 0.5, .w = 1.0 };
const PROGRESS_NUM_TICKS = 3000;
const PATH_MAX_POINTS = 500;
const CHARACTER_SPEED: f32 = (PATH_SPACING * PATH_MAX_POINTS) / PROGRESS_NUM_TICKS;
const AUDIENCE_ZONE = 150;
const AUDIENCE_ZONE_SQR = AUDIENCE_ZONE * AUDIENCE_ZONE;
const AUDIENCE_SPEED = CHARACTER_SPEED * 10.0;

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
    .{ .key = 17, .input = .ctrl },
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
    max_points: usize = PATH_MAX_POINTS,
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

    pub fn update(self: *Self, mouse: *MouseState) bool {
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
            return true;
        }
        if (self.is_selectable) self.delete_index = null;
        if (mouse.r_button.is_clicked) {
            if (self.delete_index) |di| {
                self.points.shrinkRetainingCapacity(di + 1);
                return true;
            }
        }
        return false;
    }

    /// All the points in the path have a certain spacing / distance between them
    /// Let dist be the distance between pos and the last point.
    /// If the distance is more than SPACING, we find the closest point in the direction
    /// If the distance is less than SPACING, we do nothing
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
        self.try_add_point(pos);
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

pub const Character = struct {
    const Self = @This();
    position: Vector2,
    size: Vector2 = .{ .x = 60, .y = 100 },
    color: Vector4_gl,
    path: Path,
    allocator: std.mem.Allocator,

    pub fn init(position: Vector2, color: Vector4_gl, allocator: std.mem.Allocator) Self {
        var self = Self{
            .position = position,
            .color = color,
            .path = Path.init(allocator),
            .allocator = allocator,
        };
        self.path.try_add_point(self.position);
        return self;
    }

    pub fn set_progress_position(self: *Self, progress: f32) void {
        const index = @floatToInt(usize, @intToFloat(f32, self.path.max_points) * progress);
        if (index >= self.path.points.items.len) {
            self.position = self.path.points.items[self.path.points.items.len - 1];
        } else {
            self.position = self.path.points.items[index];
        }
    }

    pub fn deinit(self: *Self) void {
        self.path.deinit();
    }
};

pub const Audience = struct {
    const Self = @This();
    position: Vector2,
    direction: Vector2,

    pub fn init(position: Vector2, direction: Vector2) Self {
        return Self{
            .position = position,
            .direction = direction,
        };
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
    magician: Character,
    assistant: Character,
    audience: std.ArrayList(Audience),
    active_path: ?*Path = null,
    load_data: []u8 = undefined,
    selectable_pos: ?Vector2 = null,
    progress: f32 = 0,
    is_playing: bool = false,
    delete_pos: ?Vector2 = null,
    new_audience_pos: ?Vector2 = null,
    new_audience_direction: Vector2 = .{},

    pub fn new(allocator: std.mem.Allocator, arena: std.mem.Allocator) Self {
        return Self{
            .magician = Character.init(.{ .x = 300, .y = 500 }, magician_color, allocator),
            .assistant = Character.init(.{ .x = 200, .y = 500 }, assistant_color, allocator),
            .audience = std.ArrayList(Audience).init(allocator),
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
        self.assistant.deinit();
        self.audience.deinit();
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
        const prev_ticks = self.ticks;
        self.ticks = ticks;
        self.arena = arena;
        const max_fract = self.max_fract_used();
        if (self.is_playing) {
            const dt = self.ticks - prev_ticks;
            const dp = @intToFloat(f32, dt) / PROGRESS_NUM_TICKS;
            self.progress += dp;
            if (self.progress > 1.0) {
                self.progress = 1.0;
                self.is_playing = false;
            }
            self.update_positions();
            if (self.progress > max_fract) {
                self.is_playing = false;
            }
        } else {
            const should_update_1 = self.magician.path.update(&self.inputs.mouse);
            const should_update_2 = self.assistant.path.update(&self.inputs.mouse);
            if (should_update_1 or should_update_2) {
                self.progress = 0;
                self.update_positions();
            }
        }
        if (self.inputs.get_key(.space).is_clicked) {
            self.is_playing = !self.is_playing;
        }
        if (self.inputs.get_key(.escape).is_clicked) {
            self.is_playing = false;
            self.progress = 0;
            self.update_positions();
        }
        if (self.inputs.get_key(.ctrl).is_clicked) {
            // click triggers when we hold down the key.
            if (self.new_audience_pos == null) {
                self.new_audience_pos = self.inputs.mouse.current_pos;
            }
        }
        if (self.inputs.get_key(.ctrl).is_released) {
            const aud = Audience.init(self.new_audience_pos.?, self.new_audience_direction);
            self.audience.append(aud) catch unreachable;
            self.new_audience_pos = null;
        }
        if (self.new_audience_pos) |pos| {
            self.new_audience_direction = self.inputs.mouse.current_pos.subtracted(pos).normalized().scaled(50);
        }
        for (self.audience.items) |*aud| {
            const dsqr = aud.position.distance_to_sqr(self.magician.position);
            if (dsqr < AUDIENCE_ZONE_SQR) {
                const dist = @sqrt(dsqr);
                var dir = self.magician.position.subtracted(aud.position);
                if (dist > AUDIENCE_SPEED) {
                    dir = dir.normalized().scaled(AUDIENCE_SPEED);
                }
                aud.position = aud.position.added(dir);
                aud.direction = dir.normalized().scaled(50);
            }
        }
    }

    pub fn max_fract_used(self: *Self) f32 {
        return std.math.max(self.magician.path.fract_used(), self.assistant.path.fract_used());
    }

    fn update_positions(self: *Self) void {
        self.magician.set_progress_position(self.progress);
        self.assistant.set_progress_position(self.progress);
    }

    pub fn end_frame(self: *Self) void {
        self.inputs.reset();
    }
};
