const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const glfw = @import("glfw");
const zm = @import("zmath");
const zmu = @import("zmathutil");
const zmesh = @import("zmesh");
const flecs = @import("flecs");

const gfx = @import("../gfx_d3d12.zig");
const zd3d12 = @import("zd3d12");
const zwin32 = @import("zwin32");
const w32 = zwin32.base;
const d3d12 = zwin32.d3d12;
const hrPanic = zwin32.hrPanic;

const fd = @import("../flecs_data.zig");
const IdLocal = @import("../variant.zig").IdLocal;

const IndexType = zmesh.Shape.IndexType;

const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
};
const FrameUniforms = struct {
    world_to_clip: zm.Mat,
    camera_position: [3]f32,
    time: f32,
    padding1: u32,
    padding2: u32,
    padding3: u32,
    light_count: u32,
    light_positions: [32][4]f32,
    light_radiances: [32][4]f32,
};

const DrawUniforms = struct {
    object_to_world: zm.Mat,
    basecolor_roughness: [4]f32,
};

const Mesh = struct {
    // entity: flecs.EntityId,
    id: IdLocal,
    index_offset: u32,
    vertex_offset: i32,
    num_indices: u32,
    num_vertices: u32,
};

// const SystemInit = struct {
//     arena_state: std.heap.ArenaAllocator,
//     arena_allocator: std.mem.Allocator,

//     meshes: std.ArrayList(Mesh),
//     meshes_indices: std.ArrayList(IndexType),
//     meshes_positions: std.ArrayList([3]f32),
//     meshes_normals: std.ArrayList([3]f32),

//     pub fn init(self: *SystemInit, system_allocator: std.mem.Allocator) void {
//         self.arena_state = std.heap.ArenaAllocator.init(system_allocator);
//         const arena = arena_state.allocator();

//         self.meshes = std.ArrayList(Mesh).init(system_allocator);
//         self.meshes_indices = std.ArrayList(IndexType).init(arena);
//         self.meshes_positions = std.ArrayList([3]f32).init(arena);
//         self.meshes_normals = std.ArrayList([3]f32).init(arena);
//     }

//     pub fn deinit(self: *SystemInit) void {
//         self.arena_state.deinit();
//     }

//     pub fn setupSystem(state: *SystemState) void {}
// };

const SystemState = struct {
    allocator: std.mem.Allocator,
    flecs_world: *flecs.World,
    sys: flecs.EntityId,
    // init: SystemInit,

    gfx: *gfx.D3D12State,
    pipeline: zd3d12.PipelineHandle,

    vertex_buffer: zd3d12.ResourceHandle,
    index_buffer: zd3d12.ResourceHandle,

    meshes: std.ArrayList(Mesh),
    query_camera: flecs.Query,
    query_lights: flecs.Query,
    query_mesh: flecs.Query,

    camera: struct {
        position: [3]f32 = .{ 0.0, 4.0, -4.0 },
        forward: [3]f32 = .{ 0.0, 0.0, 1.0 },
        pitch: f32 = 0.15 * math.pi,
        yaw: f32 = 0.0,
    } = .{},
};

fn appendMesh(
    id: IdLocal,
    // entity: flecs.EntityId,
    mesh: zmesh.Shape,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(IndexType),
    meshes_positions: *std.ArrayList([3]f32),
    meshes_normals: *std.ArrayList([3]f32),
) u64 {
    meshes.append(.{
        .id = id,
        // .entity = entity,
        .index_offset = @intCast(u32, meshes_indices.items.len),
        .vertex_offset = @intCast(i32, meshes_positions.items.len),
        .num_indices = @intCast(u32, mesh.indices.len),
        .num_vertices = @intCast(u32, mesh.positions.len),
    }) catch unreachable;

    meshes_indices.appendSlice(mesh.indices) catch unreachable;
    meshes_positions.appendSlice(mesh.positions) catch unreachable;
    meshes_normals.appendSlice(mesh.normals.?) catch unreachable;

    return meshes.items.len - 1;
}

fn initScene(
    allocator: std.mem.Allocator,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(IndexType),
    meshes_positions: *std.ArrayList([3]f32),
    meshes_normals: *std.ArrayList([3]f32),
) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    zmesh.init(arena);
    defer zmesh.deinit();

    {
        var mesh = zmesh.Shape.initParametricSphere(20, 20);
        defer mesh.deinit();
        mesh.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);
        mesh.unweld();
        mesh.computeNormals();

        _ = appendMesh(IdLocal.init("sphere"), mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }

    {
        var mesh = zmesh.Shape.initCube();
        defer mesh.deinit();
        mesh.unweld();
        mesh.computeNormals();

        _ = appendMesh(IdLocal.init("cube"), mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }

    {
        var mesh = zmesh.Shape.initCylinder(10, 10);
        defer mesh.deinit();
        mesh.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);
        mesh.scale(0.5, 1.0, 0.5);
        mesh.translate(0.0, 1.0, 0.0);

        // Top cap.
        var top = zmesh.Shape.initParametricDisk(10, 2);
        defer top.deinit();
        top.rotate(-math.pi * 0.5, 1.0, 0.0, 0.0);
        top.scale(0.5, 1.0, 0.5);
        top.translate(0.0, 1.0, 0.0);

        // Bottom cap.
        var bottom = zmesh.Shape.initParametricDisk(10, 2);
        defer bottom.deinit();
        bottom.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);
        bottom.scale(0.5, 1.0, 0.5);
        bottom.translate(0.0, 0.0, 0.0);

        mesh.merge(top);
        mesh.merge(bottom);
        mesh.unweld();
        mesh.computeNormals();

        _ = appendMesh(IdLocal.init("cylinder"), mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }

    {
        var mesh = zmesh.Shape.initCylinder(4, 4);
        defer mesh.deinit();
        mesh.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);
        mesh.scale(0.5, 1.0, 0.5);
        mesh.translate(0.0, 1.0, 0.0);
        mesh.unweld();
        mesh.computeNormals();

        _ = appendMesh(IdLocal.init("tree_trunk"), mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    {
        var mesh = zmesh.Shape.initCone(4, 4);
        defer mesh.deinit();
        mesh.rotate(-math.pi * 0.5, 1.0, 0.0, 0.0);
        // mesh.scale(0.5, 1.0, 0.5);
        // mesh.translate(0.0, 1.0, 0.0);
        mesh.unweld();
        mesh.computeNormals();

        _ = appendMesh(IdLocal.init("tree_crown"), mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
}

pub fn create(name: IdLocal, allocator: std.mem.Allocator, gfxstate: *gfx.D3D12State, flecs_world: *flecs.World) !*SystemState {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pipeline = blk: {
        // TODO: Replace InputAssembly with vertex fetch in shader
        const input_layout_desc = [_]d3d12.INPUT_ELEMENT_DESC{
            d3d12.INPUT_ELEMENT_DESC.init("POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0),
            d3d12.INPUT_ELEMENT_DESC.init("_Normal", 0, .R32G32B32_FLOAT, 0, @offsetOf(Vertex, "normal"), .PER_VERTEX_DATA, 0),
        };

        var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
        // TODO: Replace InputAssembly with vertex fetch in shader
        pso_desc.InputLayout = .{
            .pInputElementDescs = &input_layout_desc,
            .NumElements = input_layout_desc.len,
        };
        pso_desc.RTVFormats[0] = .R8G8B8A8_UNORM;
        pso_desc.NumRenderTargets = 1;
        pso_desc.DSVFormat = .D32_FLOAT;
        pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0xf;
        pso_desc.PrimitiveTopologyType = .TRIANGLE;

        break :blk gfxstate.gctx.createGraphicsShaderPipeline(
            arena,
            &pso_desc,
            "shaders/basic_pbr.vs.cso",
            "shaders/basic_pbr_mesh.ps.cso",
        );
    };

    var meshes = std.ArrayList(Mesh).init(allocator);
    var meshes_indices = std.ArrayList(IndexType).init(arena);
    var meshes_positions = std.ArrayList([3]f32).init(arena);
    var meshes_normals = std.ArrayList([3]f32).init(arena);
    initScene(allocator, &meshes, &meshes_indices, &meshes_positions, &meshes_normals);

    const total_num_vertices = @intCast(u32, meshes_positions.items.len);
    const total_num_indices = @intCast(u32, meshes_indices.items.len);

    // Create a vertex buffer.
    const vertex_buffer = gfxstate.gctx.createCommittedResource(
        .DEFAULT,
        d3d12.HEAP_FLAG_NONE,
        &d3d12.RESOURCE_DESC.initBuffer(total_num_vertices * @sizeOf(Vertex)),
        d3d12.RESOURCE_STATE_COMMON,
        null,
    ) catch |err| hrPanic(err);

    // Create an index buffer.
    const index_buffer = gfxstate.gctx.createCommittedResource(
        .DEFAULT,
        d3d12.HEAP_FLAG_NONE,
        // TODO: Get the size of IndexType
        // &d3d12.RESOURCE_DESC.initBuffer(total_num_indices * @sizeOf(IndexType)),
        &d3d12.RESOURCE_DESC.initBuffer(total_num_indices * @sizeOf(u32)),
        d3d12.RESOURCE_STATE_COMMON,
        null,
    ) catch |err| hrPanic(err);

    gfxstate.gctx.beginFrame();

    gfxstate.gctx.addTransitionBarrier(vertex_buffer, d3d12.RESOURCE_STATE_COPY_DEST);
    gfxstate.gctx.addTransitionBarrier(index_buffer, d3d12.RESOURCE_STATE_COPY_DEST);
    gfxstate.gctx.flushResourceBarriers();

    // Fill vertex buffer with vertex data.
    {
        const verts = gfxstate.gctx.allocateUploadBufferRegion(Vertex, total_num_vertices);
        for (meshes_positions.items) |_, i| {
            verts.cpu_slice[i].position = meshes_positions.items[i];
            verts.cpu_slice[i].normal = meshes_normals.items[i];
        }

        gfxstate.gctx.cmdlist.CopyBufferRegion(
            gfxstate.gctx.lookupResource(vertex_buffer).?,
            0,
            verts.buffer,
            verts.buffer_offset,
            verts.cpu_slice.len * @sizeOf(@TypeOf(verts.cpu_slice[0])),
        );
    }

    // Fill index buffer with indices.
    {
        // TODO: Make this work with IndexType instead of hardcoding u32
        const indices = gfxstate.gctx.allocateUploadBufferRegion(u32, total_num_indices);
        for (meshes_indices.items) |_, i| {
            indices.cpu_slice[i] = meshes_indices.items[i];
        }

        // Fill index buffer with index data.
        gfxstate.gctx.cmdlist.CopyBufferRegion(
            gfxstate.gctx.lookupResource(index_buffer).?,
            0,
            indices.buffer,
            indices.buffer_offset,
            indices.cpu_slice.len * @sizeOf(@TypeOf(indices.cpu_slice[0])),
        );
    }

    gfxstate.gctx.addTransitionBarrier(vertex_buffer, d3d12.RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER);
    gfxstate.gctx.addTransitionBarrier(index_buffer, d3d12.RESOURCE_STATE_INDEX_BUFFER);
    gfxstate.gctx.flushResourceBarriers();

    gfxstate.gctx.endFrame();
    gfxstate.gctx.finishGpuCommands();

    var state = allocator.create(SystemState) catch unreachable;
    var sys = flecs_world.newWrappedRunSystem(name.toCString(), .on_update, fd.NOCOMP, update, .{ .ctx = state });
    // var sys_post = flecs_world.newWrappedRunSystem(name.toCString(), .post_update, fd.NOCOMP, post_update, .{ .ctx = state });

    // Queries
    var query_builder_camera = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_camera
        .withReadonly(fd.Camera)
        .withReadonly(fd.Transform);
    var query_builder_lights = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_lights
        .with(fd.Light)
        .with(fd.Transform);
    var query_builder_mesh = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_mesh
        .withReadonly(fd.Transform)
        .withReadonly(fd.Scale)
        .withReadonly(fd.ShapeMeshInstance);
    var query_camera = query_builder_camera.buildQuery();
    var query_lights = query_builder_lights.buildQuery();
    var query_mesh = query_builder_mesh.buildQuery();

    state.* = .{
        .allocator = allocator,
        .flecs_world = flecs_world,
        .sys = sys,
        .gfx = gfxstate,
        .pipeline = pipeline,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .meshes = meshes,
        .query_camera = query_camera,
        .query_lights = query_lights,
        .query_mesh = query_mesh,
    };

    // flecs_world.observer(ShapeMeshDefinitionObserverCallback, .on_set, state);
    flecs_world.observer(ShapeMeshInstanceObserverCallback, .on_set, state);

    return state;
}

pub fn destroy(state: *SystemState) void {
    state.query_camera.deinit();
    state.query_lights.deinit();
    state.query_mesh.deinit();
    state.meshes.deinit();
    state.allocator.destroy(state);
}

// ██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗
// ██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝
// ██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗
// ██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝
// ╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗
//  ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝

fn update(iter: *flecs.Iterator(fd.NOCOMP)) void {
    var state = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), iter.iter.ctx));

    const CameraQueryComps = struct {
        cam: *const fd.Camera,
        transform: *const fd.Transform,
    };
    var camera_comps: ?CameraQueryComps = blk: {
        var entity_iter_camera = state.query_camera.iterator(CameraQueryComps);
        while (entity_iter_camera.next()) |comps| {
            if (comps.cam.active) {
                break :blk comps;
            }
        }

        break :blk null;
    };

    if (camera_comps == null) {
        return;
    }

    const cam = camera_comps.?.cam;
    const cam_world_to_clip = zm.loadMat(cam.world_to_clip[0..]);

    // Set input assembler (IA) state.
    state.gfx.gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);
    const vertex_buffer_resource = state.gfx.gctx.lookupResource(state.vertex_buffer);
    state.gfx.gctx.cmdlist.IASetVertexBuffers(0, 1, &[_]d3d12.VERTEX_BUFFER_VIEW{.{
        .BufferLocation = vertex_buffer_resource.?.GetGPUVirtualAddress(),
        .SizeInBytes = @intCast(c_uint, vertex_buffer_resource.?.GetDesc().Width),
        .StrideInBytes = @sizeOf(Vertex),
    }});
    const index_buffer_resource = state.gfx.gctx.lookupResource(state.index_buffer);
    state.gfx.gctx.cmdlist.IASetIndexBuffer(&.{
        .BufferLocation = index_buffer_resource.?.GetGPUVirtualAddress(),
        .SizeInBytes = @intCast(c_uint, index_buffer_resource.?.GetDesc().Width),
        .Format = .R32_UINT, // TODO: Check index format first
    });

    state.gfx.gctx.setCurrentPipeline(state.pipeline);

    // Upload per-frame constant data.
    {
        const pos = camera_comps.?.transform.getPos00();

        const mem = state.gfx.gctx.allocateUploadMemory(FrameUniforms, 1);
        mem.cpu_slice[0].world_to_clip = zm.transpose(cam_world_to_clip);
        mem.cpu_slice[0].camera_position = pos;
        mem.cpu_slice[0].time = @floatCast(f32, state.gfx.stats.time);
        mem.cpu_slice[0].light_count = 0;

        var entity_iter_lights = state.query_lights.iterator(struct {
            light: *fd.Light,
            transform: *fd.Transform,
        });

        var light_i: u32 = 0;
        while (entity_iter_lights.next()) |comps| {
            const light_pos = comps.transform.getPos00();
            std.mem.copy(f32, mem.cpu_slice[0].light_positions[light_i][0..], light_pos[0..]);
            std.mem.copy(f32, mem.cpu_slice[0].light_radiances[light_i][0..3], comps.light.radiance.elemsConst().*[0..]);
            mem.cpu_slice[0].light_radiances[light_i][3] = comps.light.range;
            // std.debug.print("light: {any}{any}\n", .{ light_i, mem.slice[0].light_positions[light_i] });

            light_i += 1;
        }
        mem.cpu_slice[0].light_count = light_i;

        state.gfx.gctx.cmdlist.SetGraphicsRootConstantBufferView(1, mem.gpu_base);
    }

    var entity_iter_mesh = state.query_mesh.iterator(struct {
        transform: *const fd.Transform,
        scale: *const fd.Scale,
        mesh: *const fd.ShapeMeshInstance,
    });
    while (entity_iter_mesh.next()) |comps| {
        // const scale_matrix = zm.scaling(comps.scale.x, comps.scale.y, comps.scale.z);
        // const transform = zm.loadMat43(comps.transform.matrix[0..]);
        // const object_to_world = zm.mul(scale_matrix, transform);
        const object_to_world = zm.loadMat43(comps.transform.matrix[0..]);

        const mem = state.gfx.gctx.allocateUploadMemory(DrawUniforms, 1);
        mem.cpu_slice[0].object_to_world = zm.transpose(object_to_world);
        mem.cpu_slice[0].basecolor_roughness[0] = comps.mesh.basecolor_roughness.r;
        mem.cpu_slice[0].basecolor_roughness[1] = comps.mesh.basecolor_roughness.g;
        mem.cpu_slice[0].basecolor_roughness[2] = comps.mesh.basecolor_roughness.b;
        mem.cpu_slice[0].basecolor_roughness[3] = comps.mesh.basecolor_roughness.roughness;
        state.gfx.gctx.cmdlist.SetGraphicsRootConstantBufferView(0, mem.gpu_base);

        // std.log.debug("Index count: {}. Index offset: {}", .{state.meshes.items[comps.mesh.mesh_index].num_indices, state.meshes.items[comps.mesh.mesh_index].index_offset});
        // Draw.
        state.gfx.gctx.cmdlist.DrawIndexedInstanced(
            state.meshes.items[comps.mesh.mesh_index].num_indices,
            1,
            state.meshes.items[comps.mesh.mesh_index].index_offset,
            state.meshes.items[comps.mesh.mesh_index].vertex_offset,
            0,
        );
    }
}

// const ShapeMeshDefinitionObserverCallback = struct {
//     comp: *const fd.CIShapeMeshDefinition,

//     pub const name = "CIShapeMeshDefinition";
//     pub const run = onSetCIShapeMeshDefinition;
// };

const ShapeMeshInstanceObserverCallback = struct {
    comp: *const fd.CIShapeMeshInstance,

    pub const name = "CIShapeMeshInstance";
    pub const run = onSetCIShapeMeshInstance;
};

// fn onSetCIShapeMeshDefinition(it: *flecs.Iterator(ShapeMeshDefinitionObserverCallback)) void {
//     var observer = @ptrCast(*flecs.c.ecs_observer_t, @alignCast(@alignOf(flecs.c.ecs_observer_t), it.iter.ctx));
//     var state = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), observer.*.ctx));

//     while (it.next()) |_| {
//         const ci_ptr = flecs.c.ecs_term_w_size(it.iter, @sizeOf(fd.CIShapeMeshDefinition), @intCast(i32, it.index)).?;
//         var ci = @ptrCast(*fd.CIShapeMeshDefinition, @alignCast(@alignOf(fd.CIShapeMeshDefinition), ci_ptr));

//         const ent = it.entity();
//         const mesh_index = appendMesh(
//             ci.id,
//             ent.id,
//             ci.shape,
//             &state.meshes,
//             &state.meshes_indices,
//             &state.meshes_positions,
//             &state.meshes_normals,
//         );

//         ent.remove(fd.CIShapeMeshDefinition);
//         ent.set(fd.ShapeMeshDefinition{
//             .id = ci.id,
//             .mesh_index = mesh_index,
//         });
//     }
// }

fn onSetCIShapeMeshInstance(it: *flecs.Iterator(ShapeMeshInstanceObserverCallback)) void {
    var observer = @ptrCast(*flecs.c.ecs_observer_t, @alignCast(@alignOf(flecs.c.ecs_observer_t), it.iter.ctx));
    var state = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), observer.*.ctx));

    while (it.next()) |_| {
        const ci_ptr = flecs.c.ecs_term_w_size(it.iter, @sizeOf(fd.CIShapeMeshInstance), @intCast(i32, it.index)).?;
        var ci = @ptrCast(*fd.CIShapeMeshInstance, @alignCast(@alignOf(fd.CIShapeMeshInstance), ci_ptr));

        const mesh_index = mesh_blk: {
            for (state.meshes.items) |mesh, i| {
                if (mesh.id.eqlHash(ci.id)) {
                    break :mesh_blk i;
                }
            }
            unreachable;
        };

        const ent = it.entity();
        ent.remove(fd.CIShapeMeshInstance);
        ent.set(fd.ShapeMeshInstance{
            .mesh_index = mesh_index,
            .basecolor_roughness = ci.basecolor_roughness,
        });
    }
}
