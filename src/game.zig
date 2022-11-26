const std = @import("std");
const args = @import("args");
const flecs = @import("flecs");
const RndGen = std.rand.DefaultPrng;

const window = @import("window.zig");
const gfx = @import("gfx_wgpu.zig");
const camera_system = @import("systems/camera_system.zig");
const city_system = @import("systems/procgen/city_system.zig");
// const gui_system = @import("systems/gui_system.zig");
const input_system = @import("systems/input_system.zig");
const input = @import("input.zig");
const physics_system = @import("systems/physics_system.zig");
const procmesh_system = @import("systems/procedural_mesh_system.zig");
const state_machine_system = @import("systems/state_machine_system.zig");
const terrain_system = @import("systems/terrain_system.zig");
const triangle_system = @import("systems/triangle_system.zig");
const fd = @import("flecs_data.zig");
const config = @import("config.zig");
const IdLocal = @import("variant.zig").IdLocal;
const znoise = @import("znoise");
const ztracy = @import("ztracy");

const fsm = @import("fsm/fsm.zig");

pub fn run() void {
    const tracy_zone = ztracy.ZoneNC(@src(), "Game Run", 0x00_ff_00_00);
    defer tracy_zone.End();

    var flecs_world = flecs.World.init();
    defer flecs_world.deinit();

    window.init(std.heap.page_allocator) catch unreachable;
    defer window.deinit();
    const main_window = window.createWindow("The Elvengroin Legacy") catch unreachable;

    var gfx_state = gfx.init(std.heap.page_allocator, main_window) catch unreachable;
    defer gfx.deinit(&gfx_state);

    const keymap = blk: {
        var keyboard_map = input.DeviceKeyMap{
            .device_type = .keyboard,
            .bindings = std.ArrayList(input.KeyBinding).init(std.heap.page_allocator),
        };
        keyboard_map.bindings.ensureTotalCapacity(8) catch unreachable;
        keyboard_map.bindings.appendAssumeCapacity(.{ .target_id = config.input_move_left, .source = input.KeyBindingSource{ .keyboard = .a } });
        keyboard_map.bindings.appendAssumeCapacity(.{ .target_id = config.input_move_right, .source = input.KeyBindingSource{ .keyboard = .d } });
        keyboard_map.bindings.appendAssumeCapacity(.{ .target_id = config.input_move_forward, .source = input.KeyBindingSource{ .keyboard = .w } });
        keyboard_map.bindings.appendAssumeCapacity(.{ .target_id = config.input_move_backward, .source = input.KeyBindingSource{ .keyboard = .s } });
        keyboard_map.bindings.appendAssumeCapacity(.{ .target_id = config.input_move_slow, .source = input.KeyBindingSource{ .keyboard = .left_control } });
        keyboard_map.bindings.appendAssumeCapacity(.{ .target_id = config.input_move_fast, .source = input.KeyBindingSource{ .keyboard = .left_shift } });

        var layer_on_foot = input.KeyMapLayer{
            .id = IdLocal.init("on_foot"),
            .active = true,
            .device_maps = std.ArrayList(input.DeviceKeyMap).init(std.heap.page_allocator),
        };
        layer_on_foot.device_maps.append(keyboard_map) catch unreachable;

        var map = input.KeyMap{
            .stack = std.ArrayList(input.KeyMapLayer).init(std.heap.page_allocator),
        };
        map.stack.append(layer_on_foot) catch unreachable;
        break :blk map;
    };

    var input_frame_data = input.FrameData.create(std.heap.page_allocator, keymap, main_window);
    var input_sys = try input_system.create(
        IdLocal.init("input_sys"),
        std.heap.c_allocator,
        &flecs_world,
        &input_frame_data,
    );
    defer input_system.destroy(input_sys);

    var state_machine_sys = try state_machine_system.create(
        IdLocal.init("state_machine_sys"),
        std.heap.c_allocator,
        &flecs_world,
        &input_frame_data,
    );
    defer state_machine_system.destroy(state_machine_sys);

    var physics_sys = try physics_system.create(
        IdLocal.init("physics_system_{}"),
        std.heap.page_allocator,
        &flecs_world,
    );
    defer physics_system.destroy(physics_sys);

    // var triangle_sys = try triangle_system.create(IdLocal.initFormat("triangle_system_{}", .{0}), std.heap.page_allocator, &gfx_state, &flecs_world);
    // defer triangle_system.destroy(triangle_sys);
    // var ts2 = try triangle_system.create(IdLocal.initFormat("triangle_system_{}", .{1}), std.heap.page_allocator, &gfx_state, &flecs_world);
    // defer triangle_system.destroy(ts2);

    var procmesh_sys = try procmesh_system.create(
        IdLocal.initFormat("procmesh_system_{}", .{0}),
        std.heap.page_allocator,
        &gfx_state,
        &flecs_world,
    );
    defer procmesh_system.destroy(procmesh_sys);

    const terrain_noise: znoise.FnlGenerator = .{
        .seed = @intCast(i32, 1234),
        .fractal_type = .fbm,
        .frequency = 0.0001,
        .octaves = 10,
    };

    var terrain_sys = try terrain_system.create(
        IdLocal.init("terrain_system"),
        std.heap.c_allocator,
        &gfx_state,
        &flecs_world,
        physics_sys.physics_world,
        terrain_noise,
    );
    defer terrain_system.destroy(terrain_sys);

    var city_sys = try city_system.create(
        IdLocal.init("city_system"),
        std.heap.c_allocator,
        &gfx_state,
        &flecs_world,
        physics_sys.physics_world,
        terrain_noise,
    );
    defer city_system.destroy(city_sys);

    var camera_sys = try camera_system.create(
        IdLocal.init("camera_system"),
        std.heap.page_allocator,
        &gfx_state,
        &flecs_world,
        physics_sys.physics_world,
    );
    defer camera_system.destroy(camera_sys);

    // var gui_sys = try gui_system.create(
    //     std.heap.page_allocator,
    //     &gfx_state,
    //     main_window,
    // );
    // defer gui_system.destroy(&gui_sys);

    // ███████╗███╗   ██╗████████╗██╗████████╗██╗███████╗███████╗
    // ██╔════╝████╗  ██║╚══██╔══╝██║╚══██╔══╝██║██╔════╝██╔════╝
    // █████╗  ██╔██╗ ██║   ██║   ██║   ██║   ██║█████╗  ███████╗
    // ██╔══╝  ██║╚██╗██║   ██║   ██║   ██║   ██║██╔══╝  ╚════██║
    // ███████╗██║ ╚████║   ██║   ██║   ██║   ██║███████╗███████║
    // ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝   ╚═╝   ╚═╝╚══════╝╚══════╝

    // const entity3 = flecs_world.newEntity();
    // entity3.set(fd.Transform.init(150, 500, 0.6));
    // entity3.set(fd.Scale.createScalar(10.5));
    // // entity3.set(fd.Velocity{ .x = -10, .y = 0, .z = 0 });
    // entity3.set(fd.CIShapeMeshInstance{
    //     .id = IdLocal.id64("sphere"),
    //     .basecolor_roughness = .{ .r = 0.7, .g = 0.0, .b = 1.0, .roughness = 0.8 },
    // });
    // entity3.set(fd.CIPhysicsBody{
    //     .shape_type = .sphere,
    //     .mass = 1,
    //     .sphere = .{ .radius = 10.5 },
    // });

    const debug_camera_ent = flecs_world.newEntity();
    debug_camera_ent.set(fd.Position{ .x = 200, .y = 200, .z = 50 });
    debug_camera_ent.set(fd.CICamera{
        .lookat = .{ .x = 0, .y = 1, .z = 30 },
        .near = 0.1,
        .far = 10000,
        .window = main_window,
        .active = true,
        .class = 0,
    });
    debug_camera_ent.set(fd.WorldLoader{
        .range = 2,
    });
    debug_camera_ent.set(fd.Input{ .active = true });
    debug_camera_ent.set(fd.CIFSM{ .state_machine_hash = IdLocal.id64("debug_camera") });

    // ██████╗ ██╗      █████╗ ██╗   ██╗███████╗██████╗
    // ██╔══██╗██║     ██╔══██╗╚██╗ ██╔╝██╔════╝██╔══██╗
    // ██████╔╝██║     ███████║ ╚████╔╝ █████╗  ██████╔╝
    // ██╔═══╝ ██║     ██╔══██║  ╚██╔╝  ██╔══╝  ██╔══██╗
    // ██║     ███████╗██║  ██║   ██║   ███████╗██║  ██║
    // ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝

    const player_height = config.noise_scale_y * (config.noise_offset_y + terrain_noise.noise2(20 * config.noise_scale_xz, 20 * config.noise_scale_xz));
    const player_ent = flecs_world.newEntity();
    player_ent.set(fd.Position{ .x = 20, .y = player_height + 1, .z = 20 });
    player_ent.set(fd.EulerRotation{});
    player_ent.set(fd.Scale.createScalar(1.7));
    player_ent.set(fd.Transform.init(20, player_height, 20));
    player_ent.set(fd.Forward{});
    player_ent.set(fd.Velocity{});
    player_ent.set(fd.Dynamic{});
    player_ent.set(fd.CIFSM{ .state_machine_hash = IdLocal.id64("player_controller") });
    player_ent.set(fd.CIShapeMeshInstance{
        .id = IdLocal.id64("cylinder"),
        .basecolor_roughness = .{ .r = 1.0, .g = 1.0, .b = 1.0, .roughness = 0.8 },
    });
    player_ent.set(fd.WorldLoader{
        .range = 2,
    });
    player_ent.setName("player");
    player_ent.set(fd.Input{ .active = true });
    player_ent.set(fd.Light{ .radiance = .{ .r = 4, .g = 2, .b = 1 }, .range = 10 });

    const player_camera_ent = flecs_world.newEntity();
    player_camera_ent.set(fd.Position{ .x = 5, .y = 1, .z = 5 });
    player_camera_ent.set(fd.EulerRotation{});
    player_camera_ent.set(fd.Scale.createScalar(1.7));
    player_camera_ent.set(fd.Transform{});
    player_camera_ent.set(fd.Dynamic{});
    player_camera_ent.set(fd.CICamera{
        .lookat = .{ .x = 0, .y = 1, .z = 30 },
        .near = 0.1,
        .far = 10000,
        .window = main_window,
        .active = false,
        .class = 1,
    });
    player_camera_ent.childOf(player_ent);
    player_camera_ent.setName("playercamera");
    player_camera_ent.set(fd.CIShapeMeshInstance{
        .id = IdLocal.id64("cylinder"),
        .basecolor_roughness = .{ .r = 1.0, .g = 1.0, .b = 1.0, .roughness = 0.8 },
    });

    _ = flecs_world.pair(flecs.c.EcsOnDeleteObject, flecs.c.EcsOnDelete);

    // ██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗
    // ██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝
    // ██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗
    // ██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝
    // ╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗
    //  ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝

    while (true) {
        const window_status = window.update() catch unreachable;
        if (window_status == .no_windows) {
            break;
        }

        const stats = gfx_state.gctx.stats;
        // const dt = @floatCast(f32, stats.delta_time) * 0.2;
        const dt = @floatCast(f32, stats.delta_time);
        gfx.update(&gfx_state);
        // gui_system.preUpdate(&gui_sys);

        flecs_world.progress(dt);
        // gui_system.update(&gui_sys);
        gfx.draw(&gfx_state);
    }
}
