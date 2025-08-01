pub const BuildOptions = struct {
    has_macos_sdk: bool,
    has_ios_sdk: bool,
    has_symlinks: bool,
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    use_llvm: bool = true,
    use_lld: bool = false,
    strip: ?bool = null,
};

pub fn addTestStep(b: *Build, prefix: []const u8, opts: Options) *Step {
    const target = opts.target.query.zigTriple(b.allocator) catch @panic("OOM");
    const optimize = @tagName(opts.optimize);
    const use_llvm = if (opts.use_llvm) "llvm" else "no-llvm";
    const use_lld = if (opts.use_lld) "lld" else "no-lld";
    if (opts.strip) |strip| {
        const s = if (strip) "strip" else "no-strip";
        const name = std.fmt.allocPrint(b.allocator, "test-{s}-{s}-{s}-{s}-{s}-{s}", .{
            prefix, target, optimize, use_llvm, use_lld, s,
        }) catch @panic("OOM");
        return b.step(name, "");
    }
    const name = std.fmt.allocPrint(b.allocator, "test-{s}-{s}-{s}-{s}-{s}", .{
        prefix, target, optimize, use_llvm, use_lld,
    }) catch @panic("OOM");
    return b.step(name, "");
}

const OverlayOptions = struct {
    name: []const u8,
    asm_source_bytes: ?[]const u8 = null,
    c_source_bytes: ?[]const u8 = null,
    c_source_flags: []const []const u8 = &.{},
    cpp_source_bytes: ?[]const u8 = null,
    cpp_source_flags: []const []const u8 = &.{},
    objc_source_bytes: ?[]const u8 = null,
    objc_source_flags: []const []const u8 = &.{},
    objcpp_source_bytes: ?[]const u8 = null,
    objcpp_source_flags: []const []const u8 = &.{},
    zig_source_bytes: ?[]const u8 = null,
    pic: ?bool = null,
    strip: ?bool = null,
};

pub fn addExecutable(b: *std.Build, base: Options, overlay: OverlayOptions) *Compile {
    return b.addExecutable(.{
        .name = overlay.name,
        .root_module = createModule(b, base, overlay),
        .use_llvm = base.use_llvm,
        .use_lld = base.use_lld,
    });
}

pub fn addObject(b: *Build, base: Options, overlay: OverlayOptions) *Compile {
    return b.addObject(.{
        .name = overlay.name,
        .root_module = createModule(b, base, overlay),
        .use_llvm = base.use_llvm,
        .use_lld = base.use_lld,
    });
}

pub fn addStaticLibrary(b: *Build, base: Options, overlay: OverlayOptions) *Compile {
    return b.addLibrary(.{
        .linkage = .static,
        .name = overlay.name,
        .root_module = createModule(b, base, overlay),
        .use_llvm = base.use_llvm,
        .use_lld = base.use_lld,
    });
}

pub fn addSharedLibrary(b: *Build, base: Options, overlay: OverlayOptions) *Compile {
    return b.addLibrary(.{
        .linkage = .dynamic,
        .name = overlay.name,
        .root_module = createModule(b, base, overlay),
        .use_llvm = base.use_llvm,
        .use_lld = base.use_lld,
    });
}

fn createModule(b: *Build, base: Options, overlay: OverlayOptions) *Build.Module {
    const write_files = b.addWriteFiles();

    const mod = b.createModule(.{
        .target = base.target,
        .optimize = base.optimize,
        .root_source_file = rsf: {
            const bytes = overlay.zig_source_bytes orelse break :rsf null;
            const name = b.fmt("{s}.zig", .{overlay.name});
            break :rsf write_files.add(name, bytes);
        },
        .pic = overlay.pic,
        .strip = if (base.strip) |s| s else overlay.strip,
    });

    if (overlay.objcpp_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.mm", bytes),
            .flags = overlay.objcpp_source_flags,
        });
    }
    if (overlay.objc_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.m", bytes),
            .flags = overlay.objc_source_flags,
        });
    }
    if (overlay.cpp_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.cpp", bytes),
            .flags = overlay.cpp_source_flags,
        });
    }
    if (overlay.c_source_bytes) |bytes| {
        mod.addCSourceFile(.{
            .file = write_files.add("a.c", bytes),
            .flags = overlay.c_source_flags,
        });
    }
    if (overlay.asm_source_bytes) |bytes| {
        mod.addAssemblyFile(write_files.add("a.s", bytes));
    }

    return mod;
}

pub fn addRunArtifact(comp: *Compile) *Run {
    const b = comp.step.owner;
    const run = b.addRunArtifact(comp);
    run.skip_foreign_checks = true;
    return run;
}

pub fn addCSourceBytes(comp: *Compile, bytes: []const u8, flags: []const []const u8) void {
    const b = comp.step.owner;
    const file = WriteFile.create(b).add("a.c", bytes);
    comp.root_module.addCSourceFile(.{ .file = file, .flags = flags });
}

pub fn addCppSourceBytes(comp: *Compile, bytes: []const u8, flags: []const []const u8) void {
    const b = comp.step.owner;
    const file = WriteFile.create(b).add("a.cpp", bytes);
    comp.root_module.addCSourceFile(.{ .file = file, .flags = flags });
}

pub fn addAsmSourceBytes(comp: *Compile, bytes: []const u8) void {
    const b = comp.step.owner;
    const actual_bytes = std.fmt.allocPrint(b.allocator, "{s}\n", .{bytes}) catch @panic("OOM");
    const file = WriteFile.create(b).add("a.s", actual_bytes);
    comp.root_module.addAssemblyFile(file);
}

pub fn expectLinkErrors(comp: *Compile, test_step: *Step, expected_errors: Compile.ExpectedCompileErrors) void {
    comp.expect_errors = expected_errors;
    const bin_file = comp.getEmittedBin();
    bin_file.addStepDependencies(test_step);
}

const std = @import("std");

const Build = std.Build;
const Compile = Step.Compile;
const Run = Step.Run;
const Step = Build.Step;
const WriteFile = Step.WriteFile;
