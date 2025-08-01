//! SPIR-V Spec documentation: https://www.khronos.org/registry/spir-v/specs/unified1/SPIRV.html
//! According to above documentation, a SPIR-V module has the following logical layout:
//! Header.
//! OpCapability instructions.
//! OpExtension instructions.
//! OpExtInstImport instructions.
//! A single OpMemoryModel instruction.
//! All entry points, declared with OpEntryPoint instructions.
//! All execution-mode declarators; OpExecutionMode and OpExecutionModeId instructions.
//! Debug instructions:
//! - First, OpString, OpSourceExtension, OpSource, OpSourceContinued (no forward references).
//! - OpName and OpMemberName instructions.
//! - OpModuleProcessed instructions.
//! All annotation (decoration) instructions.
//! All type declaration instructions, constant instructions, global variable declarations, (preferably) OpUndef instructions.
//! All function declarations without a body (extern functions presumably).
//! All regular functions.

// Because SPIR-V requires re-compilation anyway, and so hot swapping will not work
// anyway, we simply generate all the code in flush. This keeps
// things considerably simpler.

const SpirV = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.link);
const Path = std.Build.Cache.Path;

const Zcu = @import("../Zcu.zig");
const InternPool = @import("../InternPool.zig");
const Compilation = @import("../Compilation.zig");
const link = @import("../link.zig");
const codegen = @import("../codegen/spirv.zig");
const trace = @import("../tracy.zig").trace;
const build_options = @import("build_options");
const Air = @import("../Air.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");

const SpvModule = @import("../codegen/spirv/Module.zig");
const Section = @import("../codegen/spirv/Section.zig");
const spec = @import("../codegen/spirv/spec.zig");
const Id = spec.Id;
const Word = spec.Word;

const BinaryModule = @import("SpirV/BinaryModule.zig");

base: link.File,

object: codegen.Object,

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*SpirV {
    const gpa = comp.gpa;
    const target = &comp.root_mod.resolved_target.result;

    assert(!comp.config.use_lld); // Caught by Compilation.Config.resolve
    assert(!comp.config.use_llvm); // Caught by Compilation.Config.resolve
    assert(target.ofmt == .spirv); // Caught by Compilation.Config.resolve
    switch (target.cpu.arch) {
        .spirv32, .spirv64 => {},
        else => unreachable, // Caught by Compilation.Config.resolve.
    }
    switch (target.os.tag) {
        .opencl, .opengl, .vulkan => {},
        else => unreachable, // Caught by Compilation.Config.resolve.
    }

    const self = try arena.create(SpirV);
    self.* = .{
        .base = .{
            .tag = .spirv,
            .comp = comp,
            .emit = emit,
            .gc_sections = options.gc_sections orelse false,
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse 0,
            .allow_shlib_undefined = options.allow_shlib_undefined orelse false,
            .file = null,
            .build_id = options.build_id,
        },
        .object = codegen.Object.init(gpa, comp.getTarget()),
    };
    errdefer self.deinit();

    // TODO: read the file and keep valid parts instead of truncating
    self.base.file = try emit.root_dir.handle.createFile(emit.sub_path, .{
        .truncate = true,
        .read = true,
    });

    return self;
}

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*SpirV {
    return createEmpty(arena, comp, emit, options);
}

pub fn deinit(self: *SpirV) void {
    self.object.deinit();
}

pub fn updateNav(self: *SpirV, pt: Zcu.PerThread, nav: InternPool.Nav.Index) link.File.UpdateNavError!void {
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    const ip = &pt.zcu.intern_pool;
    log.debug("lowering nav {f}({d})", .{ ip.getNav(nav).fqn.fmt(ip), nav });

    try self.object.updateNav(pt, nav);
}

pub fn updateExports(
    self: *SpirV,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) !void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const nav_index = switch (exported) {
        .nav => |nav| nav,
        .uav => |uav| {
            _ = uav;
            @panic("TODO: implement SpirV linker code for exporting a constant value");
        },
    };
    const nav_ty = ip.getNav(nav_index).typeOf(ip);
    const target = zcu.getTarget();
    if (ip.isFunctionType(nav_ty)) {
        const spv_decl_index = try self.object.resolveNav(zcu, nav_index);
        const cc = Type.fromInterned(nav_ty).fnCallingConvention(zcu);
        const exec_model: spec.ExecutionModel = switch (target.os.tag) {
            .vulkan, .opengl => switch (cc) {
                .spirv_vertex => .vertex,
                .spirv_fragment => .fragment,
                .spirv_kernel => .gl_compute,
                // TODO: We should integrate with the Linkage capability and export this function
                .spirv_device => return,
                else => unreachable,
            },
            .opencl => switch (cc) {
                .spirv_kernel => .kernel,
                // TODO: We should integrate with the Linkage capability and export this function
                .spirv_device => return,
                else => unreachable,
            },
            else => unreachable,
        };

        for (export_indices) |export_idx| {
            const exp = export_idx.ptr(zcu);
            try self.object.spv.declareEntryPoint(
                spv_decl_index,
                exp.opts.name.toSlice(ip),
                exec_model,
                null,
            );
        }
    }

    // TODO: Export regular functions, variables, etc using Linkage attributes.
}

pub fn flush(
    self: *SpirV,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.File.FlushError!void {
    // The goal is to never use this because it's only needed if we need to
    // write to InternPool, but flush is too late to be writing to the
    // InternPool.
    _ = tid;

    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    const tracy = trace(@src());
    defer tracy.end();

    const sub_prog_node = prog_node.start("Flush Module", 0);
    defer sub_prog_node.end();

    const comp = self.base.comp;
    const spv = &self.object.spv;
    const diags = &comp.link_diags;
    const gpa = comp.gpa;

    // We need to export the list of error names somewhere so that we can pretty-print them in the
    // executor. This is not really an important thing though, so we can just dump it in any old
    // nonsemantic instruction. For now, just put it in OpSourceExtension with a special name.
    var error_info: std.io.Writer.Allocating = .init(self.object.gpa);
    defer error_info.deinit();

    error_info.writer.writeAll("zig_errors:") catch return error.OutOfMemory;
    const ip = &self.base.comp.zcu.?.intern_pool;
    for (ip.global_error_set.getNamesFromMainThread()) |name| {
        // Errors can contain pretty much any character - to encode them in a string we must escape
        // them somehow. Easiest here is to use some established scheme, one which also preseves the
        // name if it contains no strange characters is nice for debugging. URI encoding fits the bill.
        // We're using : as separator, which is a reserved character.

        error_info.writer.writeByte(':') catch return error.OutOfMemory;
        std.Uri.Component.percentEncode(
            &error_info.writer,
            name.toSlice(ip),
            struct {
                fn isValidChar(c: u8) bool {
                    return switch (c) {
                        0, '%', ':' => false,
                        else => true,
                    };
                }
            }.isValidChar,
        ) catch return error.OutOfMemory;
    }
    try spv.sections.debug_strings.emit(gpa, .OpSourceExtension, .{
        .extension = error_info.getWritten(),
    });

    const module = try spv.finalize(arena);
    errdefer arena.free(module);

    const linked_module = self.linkModule(arena, module, sub_prog_node) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |other| return diags.fail("error while linking: {s}", .{@errorName(other)}),
    };

    self.base.file.?.writeAll(std.mem.sliceAsBytes(linked_module)) catch |err|
        return diags.fail("failed to write: {s}", .{@errorName(err)});
}

fn linkModule(self: *SpirV, a: Allocator, module: []Word, progress: std.Progress.Node) ![]Word {
    _ = self;

    const lower_invocation_globals = @import("SpirV/lower_invocation_globals.zig");
    const prune_unused = @import("SpirV/prune_unused.zig");
    const dedup = @import("SpirV/deduplicate.zig");

    var parser = try BinaryModule.Parser.init(a);
    defer parser.deinit();
    var binary = try parser.parse(module);

    try lower_invocation_globals.run(&parser, &binary, progress);
    try prune_unused.run(&parser, &binary, progress);
    try dedup.run(&parser, &binary, progress);

    return binary.finalize(a);
}
