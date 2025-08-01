const std = @import("std");
const Allocator = std.mem.Allocator;
const Target = std.Target;
const log = std.log.scoped(.codegen);
const assert = std.debug.assert;
const Signedness = std.builtin.Signedness;

const Zcu = @import("../Zcu.zig");
const Decl = Zcu.Decl;
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");

const spec = @import("spirv/spec.zig");
const Opcode = spec.Opcode;
const Word = spec.Word;
const Id = spec.Id;
const StorageClass = spec.StorageClass;

const SpvModule = @import("spirv/Module.zig");
const IdRange = SpvModule.IdRange;

const SpvSection = @import("spirv/Section.zig");
const SpvAssembler = @import("spirv/Assembler.zig");

const InstMap = std.AutoHashMapUnmanaged(Air.Inst.Index, Id);

pub fn legalizeFeatures(_: *const std.Target) *const Air.Legalize.Features {
    return comptime &.initMany(&.{
        .expand_intcast_safe,
        .expand_int_from_float_safe,
        .expand_int_from_float_optimized_safe,
        .expand_add_safe,
        .expand_sub_safe,
        .expand_mul_safe,
    });
}

pub const zig_call_abi_ver = 3;
pub const big_int_bits = 32;

const InternMap = std.AutoHashMapUnmanaged(struct { InternPool.Index, NavGen.Repr }, Id);
const PtrTypeMap = std.AutoHashMapUnmanaged(
    struct { InternPool.Index, StorageClass, NavGen.Repr },
    struct { ty_id: Id, fwd_emitted: bool },
);

const ControlFlow = union(enum) {
    const Structured = struct {
        /// This type indicates the way that a block is terminated. The
        /// state of a particular block is used to track how a jump from
        /// inside the block must reach the outside.
        const Block = union(enum) {
            const Incoming = struct {
                src_label: Id,
                /// Instruction that returns an u32 value of the
                /// `Air.Inst.Index` that control flow should jump to.
                next_block: Id,
            };

            const SelectionMerge = struct {
                /// Incoming block from the `then` label.
                /// Note that hte incoming block from the `else` label is
                /// either given by the next element in the stack.
                incoming: Incoming,
                /// The label id of the cond_br's merge block.
                /// For the top-most element in the stack, this
                /// value is undefined.
                merge_block: Id,
            };

            /// For a `selection` type block, we cannot use early exits, and we
            /// must generate a 'merge ladder' of OpSelection instructions. To that end,
            /// we keep a stack of the merges that still must be closed at the end of
            /// a block.
            ///
            /// This entire structure basically just resembles a tree like
            ///     a   x
            ///      \ /
            ///   b   o   merge
            ///    \ /
            /// c   o   merge
            ///  \ /
            ///   o   merge
            ///  /
            /// o   jump to next block
            selection: struct {
                /// In order to know which merges we still need to do, we need to keep
                /// a stack of those.
                merge_stack: std.ArrayListUnmanaged(SelectionMerge) = .empty,
            },
            /// For a `loop` type block, we can early-exit the block by
            /// jumping to the loop exit node, and we don't need to generate
            /// an entire stack of merges.
            loop: struct {
                /// The next block to jump to can be determined from any number
                /// of conditions that jump to the loop exit.
                merges: std.ArrayListUnmanaged(Incoming) = .empty,
                /// The label id of the loop's merge block.
                merge_block: Id,
            },

            fn deinit(self: *Structured.Block, a: Allocator) void {
                switch (self.*) {
                    .selection => |*merge| merge.merge_stack.deinit(a),
                    .loop => |*merge| merge.merges.deinit(a),
                }
                self.* = undefined;
            }
        };
        /// The stack of (structured) blocks that we are currently in. This determines
        /// how exits from the current block must be handled.
        block_stack: std.ArrayListUnmanaged(*Structured.Block) = .empty,
        /// Maps `block` inst indices to the variable that the block's result
        /// value must be written to.
        block_results: std.AutoHashMapUnmanaged(Air.Inst.Index, Id) = .empty,
    };

    const Unstructured = struct {
        const Incoming = struct {
            src_label: Id,
            break_value_id: Id,
        };

        const Block = struct {
            label: ?Id = null,
            incoming_blocks: std.ArrayListUnmanaged(Incoming) = .empty,
        };

        /// We need to keep track of result ids for block labels, as well as the 'incoming'
        /// blocks for a block.
        blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, *Block) = .empty,
    };

    structured: Structured,
    unstructured: Unstructured,

    pub fn deinit(self: *ControlFlow, a: Allocator) void {
        switch (self.*) {
            .structured => |*cf| {
                cf.block_stack.deinit(a);
                cf.block_results.deinit(a);
            },
            .unstructured => |*cf| {
                cf.blocks.deinit(a);
            },
        }
        self.* = undefined;
    }
};

/// This structure holds information that is relevant to the entire compilation,
/// in contrast to `NavGen`, which only holds relevant information about a
/// single decl.
pub const Object = struct {
    /// A general-purpose allocator that can be used for any allocation for this Object.
    gpa: Allocator,

    /// the SPIR-V module that represents the final binary.
    spv: SpvModule,

    /// The Zig module that this object file is generated for.
    /// A map of Zig decl indices to SPIR-V decl indices.
    nav_link: std.AutoHashMapUnmanaged(InternPool.Nav.Index, SpvModule.Decl.Index) = .empty,

    /// A map of Zig InternPool indices for anonymous decls to SPIR-V decl indices.
    uav_link: std.AutoHashMapUnmanaged(struct { InternPool.Index, StorageClass }, SpvModule.Decl.Index) = .empty,

    /// A map that maps AIR intern pool indices to SPIR-V result-ids.
    intern_map: InternMap = .empty,

    /// This map serves a dual purpose:
    /// - It keeps track of pointers that are currently being emitted, so that we can tell
    ///   if they are recursive and need an OpTypeForwardPointer.
    /// - It caches pointers by child-type. This is required because sometimes we rely on
    ///   ID-equality for pointers, and pointers constructed via `ptrType()` aren't interned
    ///   via the usual `intern_map` mechanism.
    ptr_types: PtrTypeMap = .{},

    /// For test declarations for Vulkan, we have to add a buffer.
    /// We only need to generate this once, this holds the link information
    /// related to that.
    error_buffer: ?SpvModule.Decl.Index = null,

    pub fn init(gpa: Allocator, target: *const std.Target) Object {
        return .{
            .gpa = gpa,
            .spv = SpvModule.init(gpa, target),
        };
    }

    pub fn deinit(self: *Object) void {
        self.spv.deinit();
        self.nav_link.deinit(self.gpa);
        self.uav_link.deinit(self.gpa);
        self.intern_map.deinit(self.gpa);
        self.ptr_types.deinit(self.gpa);
    }

    fn genNav(
        self: *Object,
        pt: Zcu.PerThread,
        nav_index: InternPool.Nav.Index,
        air: Air,
        liveness: Air.Liveness,
        do_codegen: bool,
    ) !void {
        const zcu = pt.zcu;
        const gpa = zcu.gpa;
        const structured_cfg = zcu.navFileScope(nav_index).mod.?.structured_cfg;

        var nav_gen = NavGen{
            .gpa = gpa,
            .object = self,
            .pt = pt,
            .spv = &self.spv,
            .owner_nav = nav_index,
            .air = air,
            .liveness = liveness,
            .intern_map = &self.intern_map,
            .ptr_types = &self.ptr_types,
            .control_flow = switch (structured_cfg) {
                true => .{ .structured = .{} },
                false => .{ .unstructured = .{} },
            },
            .current_block_label = undefined,
            .base_line = zcu.navSrcLine(nav_index),
        };
        defer nav_gen.deinit();

        nav_gen.genNav(do_codegen) catch |err| switch (err) {
            error.CodegenFail => switch (zcu.codegenFailMsg(nav_index, nav_gen.error_msg.?)) {
                error.CodegenFail => {},
                error.OutOfMemory => |e| return e,
            },
            else => |other| {
                // There might be an error that happened *after* self.error_msg
                // was already allocated, so be sure to free it.
                if (nav_gen.error_msg) |error_msg| {
                    error_msg.deinit(gpa);
                }

                return other;
            },
        };
    }

    pub fn updateFunc(
        self: *Object,
        pt: Zcu.PerThread,
        func_index: InternPool.Index,
        air: *const Air,
        liveness: *const ?Air.Liveness,
    ) !void {
        const nav = pt.zcu.funcInfo(func_index).owner_nav;
        // TODO: Separate types for generating decls and functions?
        try self.genNav(pt, nav, air.*, liveness.*.?, true);
    }

    pub fn updateNav(
        self: *Object,
        pt: Zcu.PerThread,
        nav: InternPool.Nav.Index,
    ) !void {
        try self.genNav(pt, nav, undefined, undefined, false);
    }

    /// Fetch or allocate a result id for nav index. This function also marks the nav as alive.
    /// Note: Function does not actually generate the nav, it just allocates an index.
    pub fn resolveNav(self: *Object, zcu: *Zcu, nav_index: InternPool.Nav.Index) !SpvModule.Decl.Index {
        const ip = &zcu.intern_pool;
        const entry = try self.nav_link.getOrPut(self.gpa, nav_index);
        if (!entry.found_existing) {
            const nav = ip.getNav(nav_index);
            // TODO: Extern fn?
            const kind: SpvModule.Decl.Kind = if (ip.isFunctionType(nav.typeOf(ip)))
                .func
            else switch (nav.getAddrspace()) {
                .generic => .invocation_global,
                else => .global,
            };

            entry.value_ptr.* = try self.spv.allocDecl(kind);
        }

        return entry.value_ptr.*;
    }
};

/// This structure is used to compile a declaration, and contains all relevant meta-information to deal with that.
const NavGen = struct {
    /// A general-purpose allocator that can be used for any allocations for this NavGen.
    gpa: Allocator,

    /// The object that this decl is generated into.
    object: *Object,

    /// The Zig module that we are generating decls for.
    pt: Zcu.PerThread,

    /// The SPIR-V module that instructions should be emitted into.
    /// This is the same as `self.object.spv`, repeated here for brevity.
    spv: *SpvModule,

    /// The decl we are currently generating code for.
    owner_nav: InternPool.Nav.Index,

    /// The intermediate code of the declaration we are currently generating. Note: If
    /// the declaration is not a function, this value will be undefined!
    air: Air,

    /// The liveness analysis of the intermediate code for the declaration we are currently generating.
    /// Note: If the declaration is not a function, this value will be undefined!
    liveness: Air.Liveness,

    /// An array of function argument result-ids. Each index corresponds with the
    /// function argument of the same index.
    args: std.ArrayListUnmanaged(Id) = .empty,

    /// A counter to keep track of how many `arg` instructions we've seen yet.
    next_arg_index: u32 = 0,

    /// A map keeping track of which instruction generated which result-id.
    inst_results: InstMap = .empty,

    /// A map that maps AIR intern pool indices to SPIR-V result-ids.
    /// See `Object.intern_map`.
    intern_map: *InternMap,

    /// Module's pointer types, see `Object.ptr_types`.
    ptr_types: *PtrTypeMap,

    /// This field keeps track of the current state wrt structured or unstructured control flow.
    control_flow: ControlFlow,

    /// The label of the SPIR-V block we are currently generating.
    current_block_label: Id,

    /// The code (prologue and body) for the function we are currently generating code for.
    func: SpvModule.Fn = .{},

    /// The base offset of the current decl, which is what `dbg_stmt` is relative to.
    base_line: u32,

    /// If `gen` returned `Error.CodegenFail`, this contains an explanatory message.
    /// Memory is owned by `module.gpa`.
    error_msg: ?*Zcu.ErrorMsg = null,

    /// Possible errors the `genDecl` function may return.
    const Error = error{ CodegenFail, OutOfMemory };

    /// This structure is used to return information about a type typically used for
    /// arithmetic operations. These types may either be integers, floats, or a vector
    /// of these. If the type is a scalar, 'inner type' refers to the
    /// scalar type. Otherwise, if its a vector, it refers to the vector's element type.
    const ArithmeticTypeInfo = struct {
        /// A classification of the inner type.
        const Class = enum {
            /// A boolean.
            bool,

            /// A regular, **native**, integer.
            /// This is only returned when the backend supports this int as a native type (when
            /// the relevant capability is enabled).
            integer,

            /// A regular float. These are all required to be natively supported. Floating points
            /// for which the relevant capability is not enabled are not emulated.
            float,

            /// An integer of a 'strange' size (which' bit size is not the same as its backing
            /// type. **Note**: this may **also** include power-of-2 integers for which the
            /// relevant capability is not enabled), but still within the limits of the largest
            /// natively supported integer type.
            strange_integer,

            /// An integer with more bits than the largest natively supported integer type.
            composite_integer,
        };

        /// The number of bits in the inner type.
        /// This is the actual number of bits of the type, not the size of the backing integer.
        bits: u16,

        /// The number of bits required to store the type.
        /// For `integer` and `float`, this is equal to `bits`.
        /// For `strange_integer` and `bool` this is the size of the backing integer.
        /// For `composite_integer` this is the elements count.
        backing_bits: u16,

        /// Null if this type is a scalar, or the length
        /// of the vector otherwise.
        vector_len: ?u32,

        /// Whether the inner type is signed. Only relevant for integers.
        signedness: std.builtin.Signedness,

        /// A classification of the inner type. These scenarios
        /// will all have to be handled slightly different.
        class: Class,
    };

    /// Data can be lowered into in two basic representations: indirect, which is when
    /// a type is stored in memory, and direct, which is how a type is stored when its
    /// a direct SPIR-V value.
    const Repr = enum {
        /// A SPIR-V value as it would be used in operations.
        direct,
        /// A SPIR-V value as it is stored in memory.
        indirect,
    };

    /// Free resources owned by the NavGen.
    pub fn deinit(self: *NavGen) void {
        self.args.deinit(self.gpa);
        self.inst_results.deinit(self.gpa);
        self.control_flow.deinit(self.gpa);
        self.func.deinit(self.gpa);
    }

    pub fn fail(self: *NavGen, comptime format: []const u8, args: anytype) Error {
        @branchHint(.cold);
        const zcu = self.pt.zcu;
        const src_loc = zcu.navSrcLoc(self.owner_nav);
        assert(self.error_msg == null);
        self.error_msg = try Zcu.ErrorMsg.create(zcu.gpa, src_loc, format, args);
        return error.CodegenFail;
    }

    pub fn todo(self: *NavGen, comptime format: []const u8, args: anytype) Error {
        return self.fail("TODO (SPIR-V): " ++ format, args);
    }

    /// This imports the "default" extended instruction set for the target
    /// For OpenCL, OpenCL.std.100. For Vulkan and OpenGL, GLSL.std.450.
    fn importExtendedSet(self: *NavGen) !Id {
        const target = self.spv.target;
        return switch (target.os.tag) {
            .opencl, .amdhsa => try self.spv.importInstructionSet(.open_cl_std),
            .vulkan, .opengl => try self.spv.importInstructionSet(.glsl_std_450),
            else => unreachable,
        };
    }

    /// Fetch the result-id for a previously generated instruction or constant.
    fn resolve(self: *NavGen, inst: Air.Inst.Ref) !Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        if (try self.air.value(inst, pt)) |val| {
            const ty = self.typeOf(inst);
            if (ty.zigTypeTag(zcu) == .@"fn") {
                const fn_nav = switch (zcu.intern_pool.indexToKey(val.ip_index)) {
                    .@"extern" => |@"extern"| @"extern".owner_nav,
                    .func => |func| func.owner_nav,
                    else => unreachable,
                };
                const spv_decl_index = try self.object.resolveNav(zcu, fn_nav);
                try self.func.decl_deps.put(self.spv.gpa, spv_decl_index, {});
                return self.spv.declPtr(spv_decl_index).result_id;
            }

            return try self.constant(ty, val, .direct);
        }
        const index = inst.toIndex().?;
        return self.inst_results.get(index).?; // Assertion means instruction does not dominate usage.
    }

    fn resolveUav(self: *NavGen, val: InternPool.Index) !Id {
        // TODO: This cannot be a function at this point, but it should probably be handled anyway.

        const zcu = self.pt.zcu;
        const ty = Type.fromInterned(zcu.intern_pool.typeOf(val));
        const decl_ptr_ty_id = try self.ptrType(ty, self.spvStorageClass(.generic), .indirect);

        const spv_decl_index = blk: {
            const entry = try self.object.uav_link.getOrPut(self.object.gpa, .{ val, .function });
            if (entry.found_existing) {
                try self.addFunctionDep(entry.value_ptr.*, .function);

                const result_id = self.spv.declPtr(entry.value_ptr.*).result_id;
                return try self.castToGeneric(decl_ptr_ty_id, result_id);
            }

            const spv_decl_index = try self.spv.allocDecl(.invocation_global);
            try self.addFunctionDep(spv_decl_index, .function);
            entry.value_ptr.* = spv_decl_index;
            break :blk spv_decl_index;
        };

        // TODO: At some point we will be able to generate this all constant here, but then all of
        //   constant() will need to be implemented such that it doesn't generate any at-runtime code.
        // NOTE: Because this is a global, we really only want to initialize it once. Therefore the
        //   constant lowering of this value will need to be deferred to an initializer similar to
        //   other globals.

        const result_id = self.spv.declPtr(spv_decl_index).result_id;

        {
            // Save the current state so that we can temporarily generate into a different function.
            // TODO: This should probably be made a little more robust.
            const func = self.func;
            defer self.func = func;
            const block_label = self.current_block_label;
            defer self.current_block_label = block_label;

            self.func = .{};
            defer self.func.deinit(self.gpa);

            const initializer_proto_ty_id = try self.functionType(Type.void, &.{});

            const initializer_id = self.spv.allocId();
            try self.func.prologue.emit(self.spv.gpa, .OpFunction, .{
                .id_result_type = try self.resolveType(Type.void, .direct),
                .id_result = initializer_id,
                .function_control = .{},
                .function_type = initializer_proto_ty_id,
            });
            const root_block_id = self.spv.allocId();
            try self.func.prologue.emit(self.spv.gpa, .OpLabel, .{
                .id_result = root_block_id,
            });
            self.current_block_label = root_block_id;

            const val_id = try self.constant(ty, Value.fromInterned(val), .indirect);
            try self.func.body.emit(self.spv.gpa, .OpStore, .{
                .pointer = result_id,
                .object = val_id,
            });

            try self.func.body.emit(self.spv.gpa, .OpReturn, {});
            try self.func.body.emit(self.spv.gpa, .OpFunctionEnd, {});
            try self.spv.addFunction(spv_decl_index, self.func);

            try self.spv.debugNameFmt(initializer_id, "initializer of __anon_{d}", .{@intFromEnum(val)});

            const fn_decl_ptr_ty_id = try self.ptrType(ty, .function, .indirect);
            try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpExtInst, .{
                .id_result_type = fn_decl_ptr_ty_id,
                .id_result = result_id,
                .set = try self.spv.importInstructionSet(.zig),
                .instruction = .{ .inst = 0 }, // TODO: Put this definition somewhere...
                .id_ref_4 = &.{initializer_id},
            });
        }

        return try self.castToGeneric(decl_ptr_ty_id, result_id);
    }

    fn addFunctionDep(self: *NavGen, decl_index: SpvModule.Decl.Index, storage_class: StorageClass) !void {
        if (self.spv.version.minor < 4) {
            // Before version 1.4, the interface’s storage classes are limited to the Input and Output
            if (storage_class == .input or storage_class == .output) {
                try self.func.decl_deps.put(self.spv.gpa, decl_index, {});
            }
        } else {
            try self.func.decl_deps.put(self.spv.gpa, decl_index, {});
        }
    }

    fn castToGeneric(self: *NavGen, type_id: Id, ptr_id: Id) !Id {
        if (self.spv.hasFeature(.generic_pointer)) {
            const result_id = self.spv.allocId();
            try self.func.body.emit(self.spv.gpa, .OpPtrCastToGeneric, .{
                .id_result_type = type_id,
                .id_result = result_id,
                .pointer = ptr_id,
            });
            return result_id;
        }

        return ptr_id;
    }

    /// Start a new SPIR-V block, Emits the label of the new block, and stores which
    /// block we are currently generating.
    /// Note that there is no such thing as nested blocks like in ZIR or AIR, so we don't need to
    /// keep track of the previous block.
    fn beginSpvBlock(self: *NavGen, label: Id) !void {
        try self.func.body.emit(self.spv.gpa, .OpLabel, .{ .id_result = label });
        self.current_block_label = label;
    }

    /// SPIR-V requires enabling specific integer sizes through capabilities, and so if they are not enabled, we need
    /// to emulate them in other instructions/types. This function returns, given an integer bit width (signed or unsigned, sign
    /// included), the width of the underlying type which represents it, given the enabled features for the current target.
    /// If the result is `null`, the largest type the target platform supports natively is not able to perform computations using
    /// that size. In this case, multiple elements of the largest type should be used.
    /// The backing type will be chosen as the smallest supported integer larger or equal to it in number of bits.
    /// The result is valid to be used with OpTypeInt.
    /// TODO: Should the result of this function be cached?
    fn backingIntBits(self: *NavGen, bits: u16) struct { u16, bool } {
        // The backend will never be asked to compiler a 0-bit integer, so we won't have to handle those in this function.
        assert(bits != 0);

        if (self.spv.hasFeature(.arbitrary_precision_integers) and bits <= 32) {
            return .{ bits, false };
        }

        // We require Int8 and Int16 capabilities and benefit Int64 when available.
        // 32-bit integers are always supported (see spec, 2.16.1, Data rules).
        const ints = [_]struct { bits: u16, enabled: bool }{
            .{ .bits = 8, .enabled = true },
            .{ .bits = 16, .enabled = true },
            .{ .bits = 32, .enabled = true },
            .{
                .bits = 64,
                .enabled = self.spv.hasFeature(.int64) or self.spv.target.cpu.arch == .spirv64,
            },
        };

        for (ints) |int| {
            if (bits <= int.bits and int.enabled) return .{ int.bits, false };
        }

        // Big int
        return .{ std.mem.alignForward(u16, bits, big_int_bits), true };
    }

    /// Return the amount of bits in the largest supported integer type. This is either 32 (always supported), or 64 (if
    /// the Int64 capability is enabled).
    /// Note: The extension SPV_INTEL_arbitrary_precision_integers allows any integer size (at least up to 32 bits).
    /// In theory that could also be used, but since the spec says that it only guarantees support up to 32-bit ints there
    /// is no way of knowing whether those are actually supported.
    /// TODO: Maybe this should be cached?
    fn largestSupportedIntBits(self: *NavGen) u16 {
        if (self.spv.hasFeature(.int64) or self.spv.target.cpu.arch == .spirv64) {
            return 64;
        }
        return 32;
    }

    fn arithmeticTypeInfo(self: *NavGen, ty: Type) ArithmeticTypeInfo {
        const zcu = self.pt.zcu;
        const target = self.spv.target;
        var scalar_ty = ty.scalarType(zcu);
        if (scalar_ty.zigTypeTag(zcu) == .@"enum") {
            scalar_ty = scalar_ty.intTagType(zcu);
        }
        const vector_len = if (ty.isVector(zcu)) ty.vectorLen(zcu) else null;
        return switch (scalar_ty.zigTypeTag(zcu)) {
            .bool => .{
                .bits = 1, // Doesn't matter for this class.
                .backing_bits = self.backingIntBits(1).@"0",
                .vector_len = vector_len,
                .signedness = .unsigned, // Technically, but doesn't matter for this class.
                .class = .bool,
            },
            .float => .{
                .bits = scalar_ty.floatBits(target),
                .backing_bits = scalar_ty.floatBits(target), // TODO: F80?
                .vector_len = vector_len,
                .signedness = .signed, // Technically, but doesn't matter for this class.
                .class = .float,
            },
            .int => blk: {
                const int_info = scalar_ty.intInfo(zcu);
                // TODO: Maybe it's useful to also return this value.
                const backing_bits, const big_int = self.backingIntBits(int_info.bits);
                break :blk .{
                    .bits = int_info.bits,
                    .backing_bits = backing_bits,
                    .vector_len = vector_len,
                    .signedness = int_info.signedness,
                    .class = class: {
                        if (big_int) break :class .composite_integer;
                        break :class if (backing_bits == int_info.bits) .integer else .strange_integer;
                    },
                };
            },
            .@"enum" => unreachable,
            .vector => unreachable,
            else => unreachable, // Unhandled arithmetic type
        };
    }

    /// Checks whether the type can be directly translated to SPIR-V vectors
    fn isSpvVector(self: *NavGen, ty: Type) bool {
        const zcu = self.pt.zcu;
        if (ty.zigTypeTag(zcu) != .vector) return false;

        // TODO: This check must be expanded for types that can be represented
        // as integers (enums / packed structs?) and types that are represented
        // by multiple SPIR-V values.
        const scalar_ty = ty.scalarType(zcu);
        switch (scalar_ty.zigTypeTag(zcu)) {
            .bool,
            .int,
            .float,
            => {},
            else => return false,
        }

        const elem_ty = ty.childType(zcu);
        const len = ty.vectorLen(zcu);

        if (elem_ty.isNumeric(zcu) or elem_ty.toIntern() == .bool_type) {
            if (len > 1 and len <= 4) return true;
            if (self.spv.hasFeature(.vector16)) return (len == 8 or len == 16);
        }

        return false;
    }

    /// Emits a bool constant in a particular representation.
    fn constBool(self: *NavGen, value: bool, repr: Repr) !Id {
        return switch (repr) {
            .indirect => self.constInt(Type.u1, @intFromBool(value)),
            .direct => self.spv.constBool(value),
        };
    }

    /// Emits an integer constant.
    /// This function, unlike SpvModule.constInt, takes care to bitcast
    /// the value to an unsigned int first for Kernels.
    fn constInt(self: *NavGen, ty: Type, value: anytype) !Id {
        const zcu = self.pt.zcu;
        const scalar_ty = ty.scalarType(zcu);
        const int_info = scalar_ty.intInfo(zcu);
        // Use backing bits so that negatives are sign extended
        const backing_bits, const big_int = self.backingIntBits(int_info.bits);
        assert(backing_bits != 0); // u0 is comptime

        const result_ty_id = try self.resolveType(scalar_ty, .indirect);
        const signedness: Signedness = switch (@typeInfo(@TypeOf(value))) {
            .int => |int| int.signedness,
            .comptime_int => if (value < 0) .signed else .unsigned,
            else => unreachable,
        };
        if (@sizeOf(@TypeOf(value)) >= 4 and big_int) {
            const value64: u64 = switch (signedness) {
                .signed => @bitCast(@as(i64, @intCast(value))),
                .unsigned => @as(u64, @intCast(value)),
            };
            assert(backing_bits == 64);
            return self.constructComposite(result_ty_id, &.{
                try self.constInt(.u32, @as(u32, @truncate(value64))),
                try self.constInt(.u32, @as(u32, @truncate(value64 << 32))),
            });
        }

        const final_value: spec.LiteralContextDependentNumber = switch (self.spv.target.os.tag) {
            .opencl, .amdhsa => blk: {
                const value64: u64 = switch (signedness) {
                    .signed => @bitCast(@as(i64, @intCast(value))),
                    .unsigned => @as(u64, @intCast(value)),
                };

                // Manually truncate the value to the right amount of bits.
                const truncated_value = if (backing_bits == 64)
                    value64
                else
                    value64 & (@as(u64, 1) << @intCast(backing_bits)) - 1;

                break :blk switch (backing_bits) {
                    1...32 => .{ .uint32 = @truncate(truncated_value) },
                    33...64 => .{ .uint64 = truncated_value },
                    else => unreachable,
                };
            },
            else => switch (backing_bits) {
                1...32 => if (signedness == .signed) .{ .int32 = @intCast(value) } else .{ .uint32 = @intCast(value) },
                33...64 => if (signedness == .signed) .{ .int64 = value } else .{ .uint64 = value },
                else => unreachable,
            },
        };

        const result_id = try self.spv.constant(result_ty_id, final_value);

        if (!ty.isVector(zcu)) return result_id;
        return self.constructCompositeSplat(ty, result_id);
    }

    pub fn constructComposite(self: *NavGen, result_ty_id: Id, constituents: []const Id) !Id {
        const result_id = self.spv.allocId();
        try self.func.body.emit(self.gpa, .OpCompositeConstruct, .{
            .id_result_type = result_ty_id,
            .id_result = result_id,
            .constituents = constituents,
        });
        return result_id;
    }

    /// Construct a composite at runtime with all lanes set to the same value.
    /// ty must be an aggregate type.
    fn constructCompositeSplat(self: *NavGen, ty: Type, constituent: Id) !Id {
        const zcu = self.pt.zcu;
        const n: usize = @intCast(ty.arrayLen(zcu));

        const constituents = try self.gpa.alloc(Id, n);
        defer self.gpa.free(constituents);
        @memset(constituents, constituent);

        const result_ty_id = try self.resolveType(ty, .direct);
        return self.constructComposite(result_ty_id, constituents);
    }

    /// This function generates a load for a constant in direct (ie, non-memory) representation.
    /// When the constant is simple, it can be generated directly using OpConstant instructions.
    /// When the constant is more complicated however, it needs to be constructed using multiple values. This
    /// is done by emitting a sequence of instructions that initialize the value.
    //
    /// This function should only be called during function code generation.
    fn constant(self: *NavGen, ty: Type, val: Value, repr: Repr) !Id {
        // Note: Using intern_map can only be used with constants that DO NOT generate any runtime code!!
        // Ideally that should be all constants in the future, or it should be cleaned up somehow. For
        // now, only use the intern_map on case-by-case basis by breaking to :cache.
        if (self.intern_map.get(.{ val.toIntern(), repr })) |id| {
            return id;
        }

        const pt = self.pt;
        const zcu = pt.zcu;
        const target = self.spv.target;
        const result_ty_id = try self.resolveType(ty, repr);
        const ip = &zcu.intern_pool;

        log.debug("lowering constant: ty = {f}, val = {f}, key = {s}", .{ ty.fmt(pt), val.fmtValue(pt), @tagName(ip.indexToKey(val.toIntern())) });
        if (val.isUndefDeep(zcu)) {
            return self.spv.constUndef(result_ty_id);
        }

        const cacheable_id = cache: {
            switch (ip.indexToKey(val.toIntern())) {
                .int_type,
                .ptr_type,
                .array_type,
                .vector_type,
                .opt_type,
                .anyframe_type,
                .error_union_type,
                .simple_type,
                .struct_type,
                .tuple_type,
                .union_type,
                .opaque_type,
                .enum_type,
                .func_type,
                .error_set_type,
                .inferred_error_set_type,
                => unreachable, // types, not values

                .undef => unreachable, // handled above

                .variable,
                .@"extern",
                .func,
                .enum_literal,
                .empty_enum_value,
                => unreachable, // non-runtime values

                .simple_value => |simple_value| switch (simple_value) {
                    .undefined,
                    .void,
                    .null,
                    .empty_tuple,
                    .@"unreachable",
                    => unreachable, // non-runtime values

                    .false, .true => break :cache try self.constBool(val.toBool(), repr),
                },
                .int => {
                    if (ty.isSignedInt(zcu)) {
                        break :cache try self.constInt(ty, val.toSignedInt(zcu));
                    } else {
                        break :cache try self.constInt(ty, val.toUnsignedInt(zcu));
                    }
                },
                .float => {
                    const lit: spec.LiteralContextDependentNumber = switch (ty.floatBits(target)) {
                        16 => .{ .uint32 = @as(u16, @bitCast(val.toFloat(f16, zcu))) },
                        32 => .{ .float32 = val.toFloat(f32, zcu) },
                        64 => .{ .float64 = val.toFloat(f64, zcu) },
                        80, 128 => unreachable, // TODO
                        else => unreachable,
                    };
                    break :cache try self.spv.constant(result_ty_id, lit);
                },
                .err => |err| {
                    const value = try pt.getErrorValue(err.name);
                    break :cache try self.constInt(ty, value);
                },
                .error_union => |error_union| {
                    // TODO: Error unions may be constructed with constant instructions if the payload type
                    // allows it. For now, just generate it here regardless.
                    const err_int_ty = try pt.errorIntType();
                    const err_ty = switch (error_union.val) {
                        .err_name => ty.errorUnionSet(zcu),
                        .payload => err_int_ty,
                    };
                    const err_val = switch (error_union.val) {
                        .err_name => |err_name| Value.fromInterned(try pt.intern(.{ .err = .{
                            .ty = ty.errorUnionSet(zcu).toIntern(),
                            .name = err_name,
                        } })),
                        .payload => try pt.intValue(err_int_ty, 0),
                    };
                    const payload_ty = ty.errorUnionPayload(zcu);
                    const eu_layout = self.errorUnionLayout(payload_ty);
                    if (!eu_layout.payload_has_bits) {
                        // We use the error type directly as the type.
                        break :cache try self.constant(err_ty, err_val, .indirect);
                    }

                    const payload_val = Value.fromInterned(switch (error_union.val) {
                        .err_name => try pt.intern(.{ .undef = payload_ty.toIntern() }),
                        .payload => |payload| payload,
                    });

                    var constituents: [2]Id = undefined;
                    var types: [2]Type = undefined;
                    if (eu_layout.error_first) {
                        constituents[0] = try self.constant(err_ty, err_val, .indirect);
                        constituents[1] = try self.constant(payload_ty, payload_val, .indirect);
                        types = .{ err_ty, payload_ty };
                    } else {
                        constituents[0] = try self.constant(payload_ty, payload_val, .indirect);
                        constituents[1] = try self.constant(err_ty, err_val, .indirect);
                        types = .{ payload_ty, err_ty };
                    }

                    const comp_ty_id = try self.resolveType(ty, .direct);
                    return try self.constructComposite(comp_ty_id, &constituents);
                },
                .enum_tag => {
                    const int_val = try val.intFromEnum(ty, pt);
                    const int_ty = ty.intTagType(zcu);
                    break :cache try self.constant(int_ty, int_val, repr);
                },
                .ptr => return self.constantPtr(val),
                .slice => |slice| {
                    const ptr_id = try self.constantPtr(Value.fromInterned(slice.ptr));
                    const len_id = try self.constant(Type.usize, Value.fromInterned(slice.len), .indirect);
                    const comp_ty_id = try self.resolveType(ty, .direct);
                    return try self.constructComposite(comp_ty_id, &.{ ptr_id, len_id });
                },
                .opt => {
                    const payload_ty = ty.optionalChild(zcu);
                    const maybe_payload_val = val.optionalValue(zcu);

                    if (!payload_ty.hasRuntimeBits(zcu)) {
                        break :cache try self.constBool(maybe_payload_val != null, .indirect);
                    } else if (ty.optionalReprIsPayload(zcu)) {
                        // Optional representation is a nullable pointer or slice.
                        if (maybe_payload_val) |payload_val| {
                            return try self.constant(payload_ty, payload_val, .indirect);
                        } else {
                            break :cache try self.spv.constNull(result_ty_id);
                        }
                    }

                    // Optional representation is a structure.
                    // { Payload, Bool }

                    const has_pl_id = try self.constBool(maybe_payload_val != null, .indirect);
                    const payload_id = if (maybe_payload_val) |payload_val|
                        try self.constant(payload_ty, payload_val, .indirect)
                    else
                        try self.spv.constUndef(try self.resolveType(payload_ty, .indirect));

                    const comp_ty_id = try self.resolveType(ty, .direct);
                    return try self.constructComposite(comp_ty_id, &.{ payload_id, has_pl_id });
                },
                .aggregate => |aggregate| switch (ip.indexToKey(ty.ip_index)) {
                    inline .array_type, .vector_type => |array_type, tag| {
                        const elem_ty = Type.fromInterned(array_type.child);

                        const constituents = try self.gpa.alloc(Id, @intCast(ty.arrayLenIncludingSentinel(zcu)));
                        defer self.gpa.free(constituents);

                        const child_repr: Repr = switch (tag) {
                            .array_type => .indirect,
                            .vector_type => .direct,
                            else => unreachable,
                        };

                        switch (aggregate.storage) {
                            .bytes => |bytes| {
                                // TODO: This is really space inefficient, perhaps there is a better
                                // way to do it?
                                for (constituents, bytes.toSlice(constituents.len, ip)) |*constituent, byte| {
                                    constituent.* = try self.constInt(elem_ty, byte);
                                }
                            },
                            .elems => |elems| {
                                for (constituents, elems) |*constituent, elem| {
                                    constituent.* = try self.constant(elem_ty, Value.fromInterned(elem), child_repr);
                                }
                            },
                            .repeated_elem => |elem| {
                                @memset(constituents, try self.constant(elem_ty, Value.fromInterned(elem), child_repr));
                            },
                        }

                        const comp_ty_id = try self.resolveType(ty, .direct);
                        return self.constructComposite(comp_ty_id, constituents);
                    },
                    .struct_type => {
                        const struct_type = zcu.typeToStruct(ty).?;

                        if (struct_type.layout == .@"packed") {
                            // TODO: composite int
                            // TODO: endianness
                            const bits: u16 = @intCast(ty.bitSize(zcu));
                            const bytes = std.mem.alignForward(u16, self.backingIntBits(bits).@"0", 8) / 8;
                            var limbs: [8]u8 = undefined;
                            @memset(&limbs, 0);
                            val.writeToPackedMemory(ty, pt, limbs[0..bytes], 0) catch unreachable;
                            const backing_ty = Type.fromInterned(struct_type.backingIntTypeUnordered(ip));
                            return try self.constInt(backing_ty, @as(u64, @bitCast(limbs)));
                        }

                        var types = std.ArrayList(Type).init(self.gpa);
                        defer types.deinit();

                        var constituents = std.ArrayList(Id).init(self.gpa);
                        defer constituents.deinit();

                        var it = struct_type.iterateRuntimeOrder(ip);
                        while (it.next()) |field_index| {
                            const field_ty = Type.fromInterned(struct_type.field_types.get(ip)[field_index]);
                            if (!field_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                                // This is a zero-bit field - we only needed it for the alignment.
                                continue;
                            }

                            // TODO: Padding?
                            const field_val = try val.fieldValue(pt, field_index);
                            const field_id = try self.constant(field_ty, field_val, .indirect);

                            try types.append(field_ty);
                            try constituents.append(field_id);
                        }

                        const comp_ty_id = try self.resolveType(ty, .direct);
                        return try self.constructComposite(comp_ty_id, constituents.items);
                    },
                    .tuple_type => return self.todo("implement tuple types", .{}),
                    else => unreachable,
                },
                .un => |un| {
                    if (un.tag == .none) {
                        assert(ty.containerLayout(zcu) == .@"packed"); // TODO
                        const int_ty = try pt.intType(.unsigned, @intCast(ty.bitSize(zcu)));
                        return try self.constant(int_ty, Value.fromInterned(un.val), .direct);
                    }
                    const active_field = ty.unionTagFieldIndex(Value.fromInterned(un.tag), zcu).?;
                    const union_obj = zcu.typeToUnion(ty).?;
                    const field_ty = Type.fromInterned(union_obj.field_types.get(ip)[active_field]);
                    const payload = if (field_ty.hasRuntimeBitsIgnoreComptime(zcu))
                        try self.constant(field_ty, Value.fromInterned(un.val), .direct)
                    else
                        null;
                    return try self.unionInit(ty, active_field, payload);
                },
                .memoized_call => unreachable,
            }
        };

        try self.intern_map.putNoClobber(self.gpa, .{ val.toIntern(), repr }, cacheable_id);

        return cacheable_id;
    }

    fn constantPtr(self: *NavGen, ptr_val: Value) Error!Id {
        const pt = self.pt;

        if (ptr_val.isUndef(pt.zcu)) {
            const result_ty = ptr_val.typeOf(pt.zcu);
            const result_ty_id = try self.resolveType(result_ty, .direct);
            return self.spv.constUndef(result_ty_id);
        }

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        const derivation = try ptr_val.pointerDerivation(arena.allocator(), pt);
        return self.derivePtr(derivation);
    }

    fn derivePtr(self: *NavGen, derivation: Value.PointerDeriveStep) Error!Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        switch (derivation) {
            .comptime_alloc_ptr, .comptime_field_ptr => unreachable,
            .int => |int| {
                const result_ty_id = try self.resolveType(int.ptr_ty, .direct);
                // TODO: This can probably be an OpSpecConstantOp Bitcast, but
                // that is not implemented by Mesa yet. Therefore, just generate it
                // as a runtime operation.
                const result_ptr_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpConvertUToPtr, .{
                    .id_result_type = result_ty_id,
                    .id_result = result_ptr_id,
                    .integer_value = try self.constant(Type.usize, try pt.intValue(Type.usize, int.addr), .direct),
                });
                return result_ptr_id;
            },
            .nav_ptr => |nav| {
                const result_ptr_ty = try pt.navPtrType(nav);
                return self.constantNavRef(result_ptr_ty, nav);
            },
            .uav_ptr => |uav| {
                const result_ptr_ty = Type.fromInterned(uav.orig_ty);
                return self.constantUavRef(result_ptr_ty, uav);
            },
            .eu_payload_ptr => @panic("TODO"),
            .opt_payload_ptr => @panic("TODO"),
            .field_ptr => |field| {
                const parent_ptr_id = try self.derivePtr(field.parent.*);
                const parent_ptr_ty = try field.parent.ptrType(pt);
                return self.structFieldPtr(field.result_ptr_ty, parent_ptr_ty, parent_ptr_id, field.field_idx);
            },
            .elem_ptr => |elem| {
                const parent_ptr_id = try self.derivePtr(elem.parent.*);
                const parent_ptr_ty = try elem.parent.ptrType(pt);
                const index_id = try self.constInt(Type.usize, elem.elem_idx);
                return self.ptrElemPtr(parent_ptr_ty, parent_ptr_id, index_id);
            },
            .offset_and_cast => |oac| {
                const parent_ptr_id = try self.derivePtr(oac.parent.*);
                const parent_ptr_ty = try oac.parent.ptrType(pt);
                const result_ty_id = try self.resolveType(oac.new_ptr_ty, .direct);
                const child_size = oac.new_ptr_ty.childType(zcu).abiSize(zcu);

                if (parent_ptr_ty.childType(zcu).isVector(zcu) and oac.byte_offset % child_size == 0) {
                    // Vector element ptr accesses are derived as offset_and_cast.
                    // We can just use OpAccessChain.
                    return self.accessChain(
                        result_ty_id,
                        parent_ptr_id,
                        &.{@intCast(@divExact(oac.byte_offset, child_size))},
                    );
                }

                if (oac.byte_offset == 0) {
                    // Allow changing the pointer type child only to restructure arrays.
                    // e.g. [3][2]T to T is fine, as is [2]T -> [2][1]T.
                    const result_ptr_id = self.spv.allocId();
                    try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                        .id_result_type = result_ty_id,
                        .id_result = result_ptr_id,
                        .operand = parent_ptr_id,
                    });
                    return result_ptr_id;
                }

                return self.fail("cannot perform pointer cast: '{f}' to '{f}'", .{
                    parent_ptr_ty.fmt(pt),
                    oac.new_ptr_ty.fmt(pt),
                });
            },
        }
    }

    fn constantUavRef(
        self: *NavGen,
        ty: Type,
        uav: InternPool.Key.Ptr.BaseAddr.Uav,
    ) !Id {
        // TODO: Merge this function with constantDeclRef.

        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const ty_id = try self.resolveType(ty, .direct);
        const uav_ty = Type.fromInterned(ip.typeOf(uav.val));

        switch (ip.indexToKey(uav.val)) {
            .func => unreachable, // TODO
            .@"extern" => assert(!ip.isFunctionType(uav_ty.toIntern())),
            else => {},
        }

        // const is_fn_body = decl_ty.zigTypeTag(zcu) == .@"fn";
        if (!uav_ty.isFnOrHasRuntimeBitsIgnoreComptime(zcu)) {
            // Pointer to nothing - return undefined
            return self.spv.constUndef(ty_id);
        }

        // Uav refs are always generic.
        assert(ty.ptrAddressSpace(zcu) == .generic);
        const decl_ptr_ty_id = try self.ptrType(uav_ty, .generic, .indirect);
        const ptr_id = try self.resolveUav(uav.val);

        if (decl_ptr_ty_id != ty_id) {
            // Differing pointer types, insert a cast.
            const casted_ptr_id = self.spv.allocId();
            try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                .id_result_type = ty_id,
                .id_result = casted_ptr_id,
                .operand = ptr_id,
            });
            return casted_ptr_id;
        } else {
            return ptr_id;
        }
    }

    fn constantNavRef(self: *NavGen, ty: Type, nav_index: InternPool.Nav.Index) !Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const ty_id = try self.resolveType(ty, .direct);
        const nav = ip.getNav(nav_index);
        const nav_ty: Type = .fromInterned(nav.typeOf(ip));

        switch (nav.status) {
            .unresolved => unreachable,
            .type_resolved => {}, // this is not a function or extern
            .fully_resolved => |r| switch (ip.indexToKey(r.val)) {
                .func => {
                    // TODO: Properly lower function pointers. For now we are going to hack around it and
                    // just generate an empty pointer. Function pointers are represented by a pointer to usize.
                    return try self.spv.constUndef(ty_id);
                },
                .@"extern" => if (ip.isFunctionType(nav_ty.toIntern())) @panic("TODO"),
                else => {},
            },
        }

        if (!nav_ty.isFnOrHasRuntimeBitsIgnoreComptime(zcu)) {
            // Pointer to nothing - return undefined.
            return self.spv.constUndef(ty_id);
        }

        const spv_decl_index = try self.object.resolveNav(zcu, nav_index);
        const spv_decl = self.spv.declPtr(spv_decl_index);

        const decl_id = switch (spv_decl.kind) {
            .func => unreachable, // TODO: Is this possible?
            .global, .invocation_global => spv_decl.result_id,
        };

        const storage_class = self.spvStorageClass(nav.getAddrspace());
        try self.addFunctionDep(spv_decl_index, storage_class);

        const decl_ptr_ty_id = try self.ptrType(nav_ty, storage_class, .indirect);

        const ptr_id = switch (storage_class) {
            .generic => try self.castToGeneric(decl_ptr_ty_id, decl_id),
            else => decl_id,
        };

        if (decl_ptr_ty_id != ty_id) {
            // Differing pointer types, insert a cast.
            const casted_ptr_id = self.spv.allocId();
            try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                .id_result_type = ty_id,
                .id_result = casted_ptr_id,
                .operand = ptr_id,
            });
            return casted_ptr_id;
        } else {
            return ptr_id;
        }
    }

    // Turn a Zig type's name into a cache reference.
    fn resolveTypeName(self: *NavGen, ty: Type) ![]const u8 {
        var aw: std.io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        ty.print(&aw.writer, self.pt) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        return try aw.toOwnedSlice();
    }

    /// Create an integer type suitable for storing at least 'bits' bits.
    /// The integer type that is returned by this function is the type that is used to perform
    /// actual operations (as well as store) a Zig type of a particular number of bits. To create
    /// a type with an exact size, use SpvModule.intType.
    fn intType(self: *NavGen, signedness: std.builtin.Signedness, bits: u16) !Id {
        const backing_bits, const big_int = self.backingIntBits(bits);
        if (big_int) {
            if (backing_bits > 64) {
                return self.fail("composite integers larger than 64bit aren't supported", .{});
            }
            const int_ty = try self.resolveType(.u32, .direct);
            return self.arrayType(backing_bits / big_int_bits, int_ty);
        }

        return switch (self.spv.target.os.tag) {
            // Kernel only supports unsigned ints.
            .opencl, .amdhsa => return self.spv.intType(.unsigned, backing_bits),
            else => self.spv.intType(signedness, backing_bits),
        };
    }

    fn arrayType(self: *NavGen, len: u32, child_ty: Id) !Id {
        const len_id = try self.constInt(Type.u32, len);
        return self.spv.arrayType(len_id, child_ty);
    }

    fn ptrType(self: *NavGen, child_ty: Type, storage_class: StorageClass, child_repr: Repr) !Id {
        const zcu = self.pt.zcu;
        const ip = &zcu.intern_pool;
        const key = .{ child_ty.toIntern(), storage_class, child_repr };
        const entry = try self.ptr_types.getOrPut(self.gpa, key);
        if (entry.found_existing) {
            const fwd_id = entry.value_ptr.ty_id;
            if (!entry.value_ptr.fwd_emitted) {
                try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpTypeForwardPointer, .{
                    .pointer_type = fwd_id,
                    .storage_class = storage_class,
                });
                entry.value_ptr.fwd_emitted = true;
            }
            return fwd_id;
        }

        const result_id = self.spv.allocId();
        entry.value_ptr.* = .{
            .ty_id = result_id,
            .fwd_emitted = false,
        };

        const child_ty_id = try self.resolveType(child_ty, child_repr);

        switch (self.spv.target.os.tag) {
            .vulkan, .opengl => {
                if (child_ty.zigTypeTag(zcu) == .@"struct") {
                    switch (storage_class) {
                        .uniform, .push_constant => try self.spv.decorate(child_ty_id, .block),
                        else => {},
                    }
                }

                switch (ip.indexToKey(child_ty.toIntern())) {
                    .func_type, .opaque_type => {},
                    else => {
                        try self.spv.decorate(result_id, .{ .array_stride = .{ .array_stride = @intCast(child_ty.abiSize(zcu)) } });
                    },
                }
            },
            else => {},
        }

        try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpTypePointer, .{
            .id_result = result_id,
            .storage_class = storage_class,
            .type = child_ty_id,
        });

        self.ptr_types.getPtr(key).?.fwd_emitted = true;

        return result_id;
    }

    fn functionType(self: *NavGen, return_ty: Type, param_types: []const Type) !Id {
        const return_ty_id = try self.resolveFnReturnType(return_ty);
        const param_ids = try self.gpa.alloc(Id, param_types.len);
        defer self.gpa.free(param_ids);

        for (param_types, param_ids) |param_ty, *param_id| {
            param_id.* = try self.resolveType(param_ty, .direct);
        }

        return self.spv.functionType(return_ty_id, param_ids);
    }

    /// Generate a union type. Union types are always generated with the
    /// most aligned field active. If the tag alignment is greater
    /// than that of the payload, a regular union (non-packed, with both tag and
    /// payload), will be generated as follows:
    ///  struct {
    ///    tag: TagType,
    ///    payload: MostAlignedFieldType,
    ///    payload_padding: [payload_size - @sizeOf(MostAlignedFieldType)]u8,
    ///    padding: [padding_size]u8,
    ///  }
    /// If the payload alignment is greater than that of the tag:
    ///  struct {
    ///    payload: MostAlignedFieldType,
    ///    payload_padding: [payload_size - @sizeOf(MostAlignedFieldType)]u8,
    ///    tag: TagType,
    ///    padding: [padding_size]u8,
    ///  }
    /// If any of the fields' size is 0, it will be omitted.
    fn resolveUnionType(self: *NavGen, ty: Type) !Id {
        const zcu = self.pt.zcu;
        const ip = &zcu.intern_pool;
        const union_obj = zcu.typeToUnion(ty).?;

        if (union_obj.flagsUnordered(ip).layout == .@"packed") {
            return try self.intType(.unsigned, @intCast(ty.bitSize(zcu)));
        }

        const layout = self.unionLayout(ty);
        if (!layout.has_payload) {
            // No payload, so represent this as just the tag type.
            return try self.resolveType(Type.fromInterned(union_obj.enum_tag_ty), .indirect);
        }

        var member_types: [4]Id = undefined;
        var member_names: [4][]const u8 = undefined;

        const u8_ty_id = try self.resolveType(Type.u8, .direct);

        if (layout.tag_size != 0) {
            const tag_ty_id = try self.resolveType(Type.fromInterned(union_obj.enum_tag_ty), .indirect);
            member_types[layout.tag_index] = tag_ty_id;
            member_names[layout.tag_index] = "(tag)";
        }

        if (layout.payload_size != 0) {
            const payload_ty_id = try self.resolveType(layout.payload_ty, .indirect);
            member_types[layout.payload_index] = payload_ty_id;
            member_names[layout.payload_index] = "(payload)";
        }

        if (layout.payload_padding_size != 0) {
            const payload_padding_ty_id = try self.arrayType(@intCast(layout.payload_padding_size), u8_ty_id);
            member_types[layout.payload_padding_index] = payload_padding_ty_id;
            member_names[layout.payload_padding_index] = "(payload padding)";
        }

        if (layout.padding_size != 0) {
            const padding_ty_id = try self.arrayType(@intCast(layout.padding_size), u8_ty_id);
            member_types[layout.padding_index] = padding_ty_id;
            member_names[layout.padding_index] = "(padding)";
        }

        const result_id = self.spv.allocId();
        try self.spv.structType(result_id, member_types[0..layout.total_fields], member_names[0..layout.total_fields]);

        const type_name = try self.resolveTypeName(ty);
        defer self.gpa.free(type_name);
        try self.spv.debugName(result_id, type_name);

        return result_id;
    }

    fn resolveFnReturnType(self: *NavGen, ret_ty: Type) !Id {
        const zcu = self.pt.zcu;
        if (!ret_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            // If the return type is an error set or an error union, then we make this
            // anyerror return type instead, so that it can be coerced into a function
            // pointer type which has anyerror as the return type.
            if (ret_ty.isError(zcu)) {
                return self.resolveType(Type.anyerror, .direct);
            } else {
                return self.resolveType(Type.void, .direct);
            }
        }

        return try self.resolveType(ret_ty, .direct);
    }

    /// Turn a Zig type into a SPIR-V Type, and return a reference to it.
    fn resolveType(self: *NavGen, ty: Type, repr: Repr) Error!Id {
        if (self.intern_map.get(.{ ty.toIntern(), repr })) |id| {
            return id;
        }

        const id = try self.resolveTypeInner(ty, repr);
        try self.intern_map.put(self.gpa, .{ ty.toIntern(), repr }, id);
        return id;
    }

    fn resolveTypeInner(self: *NavGen, ty: Type, repr: Repr) Error!Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        log.debug("resolveType: ty = {f}", .{ty.fmt(pt)});
        const target = self.spv.target;

        const section = &self.spv.sections.types_globals_constants;

        switch (ty.zigTypeTag(zcu)) {
            .noreturn => {
                assert(repr == .direct);
                return try self.spv.voidType();
            },
            .void => switch (repr) {
                .direct => {
                    return try self.spv.voidType();
                },
                // Pointers to void
                .indirect => {
                    const result_id = self.spv.allocId();
                    try section.emit(self.spv.gpa, .OpTypeOpaque, .{
                        .id_result = result_id,
                        .literal_string = "void",
                    });
                    return result_id;
                },
            },
            .bool => switch (repr) {
                .direct => return try self.spv.boolType(),
                .indirect => return try self.resolveType(Type.u1, .indirect),
            },
            .int => {
                const int_info = ty.intInfo(zcu);
                if (int_info.bits == 0) {
                    // Some times, the backend will be asked to generate a pointer to i0. OpTypeInt
                    // with 0 bits is invalid, so return an opaque type in this case.
                    assert(repr == .indirect);
                    const result_id = self.spv.allocId();
                    try section.emit(self.spv.gpa, .OpTypeOpaque, .{
                        .id_result = result_id,
                        .literal_string = "u0",
                    });
                    return result_id;
                }
                return try self.intType(int_info.signedness, int_info.bits);
            },
            .@"enum" => {
                const tag_ty = ty.intTagType(zcu);
                return try self.resolveType(tag_ty, repr);
            },
            .float => {
                // We can (and want) not really emulate floating points with other floating point types like with the integer types,
                // so if the float is not supported, just return an error.
                const bits = ty.floatBits(target);
                const supported = switch (bits) {
                    16 => self.spv.hasFeature(.float16),
                    // 32-bit floats are always supported (see spec, 2.16.1, Data rules).
                    32 => true,
                    64 => self.spv.hasFeature(.float64),
                    else => false,
                };

                if (!supported) {
                    return self.fail("Floating point width of {} bits is not supported for the current SPIR-V feature set", .{bits});
                }

                return try self.spv.floatType(bits);
            },
            .array => {
                const elem_ty = ty.childType(zcu);
                const elem_ty_id = try self.resolveType(elem_ty, .indirect);
                const total_len = std.math.cast(u32, ty.arrayLenIncludingSentinel(zcu)) orelse {
                    return self.fail("array type of {} elements is too large", .{ty.arrayLenIncludingSentinel(zcu)});
                };

                if (!elem_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                    // The size of the array would be 0, but that is not allowed in SPIR-V.
                    // This path can be reached when the backend is asked to generate a pointer to
                    // an array of some zero-bit type. This should always be an indirect path.
                    assert(repr == .indirect);

                    // We cannot use the child type here, so just use an opaque type.
                    const result_id = self.spv.allocId();
                    try section.emit(self.spv.gpa, .OpTypeOpaque, .{
                        .id_result = result_id,
                        .literal_string = "zero-sized array",
                    });
                    return result_id;
                } else if (total_len == 0) {
                    // The size of the array would be 0, but that is not allowed in SPIR-V.
                    // This path can be reached for example when there is a slicing of a pointer
                    // that produces a zero-length array. In all cases where this type can be generated,
                    // this should be an indirect path.
                    assert(repr == .indirect);

                    // In this case, we have an array of a non-zero sized type. In this case,
                    // generate an array of 1 element instead, so that ptr_elem_ptr instructions
                    // can be lowered to ptrAccessChain instead of manually performing the math.
                    return try self.arrayType(1, elem_ty_id);
                } else {
                    const result_id = try self.arrayType(total_len, elem_ty_id);
                    switch (self.spv.target.os.tag) {
                        .vulkan, .opengl => {
                            try self.spv.decorate(result_id, .{ .array_stride = .{
                                .array_stride = @intCast(elem_ty.abiSize(zcu)),
                            } });
                        },
                        else => {},
                    }
                    return result_id;
                }
            },
            .vector => {
                const elem_ty = ty.childType(zcu);
                const elem_ty_id = try self.resolveType(elem_ty, repr);
                const len = ty.vectorLen(zcu);

                if (self.isSpvVector(ty)) {
                    return try self.spv.vectorType(len, elem_ty_id);
                } else {
                    return try self.arrayType(len, elem_ty_id);
                }
            },
            .@"fn" => switch (repr) {
                .direct => {
                    const fn_info = zcu.typeToFunc(ty).?;

                    comptime assert(zig_call_abi_ver == 3);
                    switch (fn_info.cc) {
                        .auto,
                        .spirv_kernel,
                        .spirv_fragment,
                        .spirv_vertex,
                        .spirv_device,
                        => {},
                        else => unreachable,
                    }

                    // Guaranteed by callConvSupportsVarArgs, there are no SPIR-V CCs which support
                    // varargs.
                    assert(!fn_info.is_var_args);

                    // Note: Logic is different from functionType().
                    const param_ty_ids = try self.gpa.alloc(Id, fn_info.param_types.len);
                    defer self.gpa.free(param_ty_ids);
                    var param_index: usize = 0;
                    for (fn_info.param_types.get(ip)) |param_ty_index| {
                        const param_ty = Type.fromInterned(param_ty_index);
                        if (!param_ty.hasRuntimeBitsIgnoreComptime(zcu)) continue;

                        param_ty_ids[param_index] = try self.resolveType(param_ty, .direct);
                        param_index += 1;
                    }

                    const return_ty_id = try self.resolveFnReturnType(Type.fromInterned(fn_info.return_type));

                    const result_id = self.spv.allocId();
                    try section.emit(self.spv.gpa, .OpTypeFunction, .{
                        .id_result = result_id,
                        .return_type = return_ty_id,
                        .id_ref_2 = param_ty_ids[0..param_index],
                    });

                    return result_id;
                },
                .indirect => {
                    // TODO: Represent function pointers properly.
                    // For now, just use an usize type.
                    return try self.resolveType(Type.usize, .indirect);
                },
            },
            .pointer => {
                const ptr_info = ty.ptrInfo(zcu);

                const child_ty = Type.fromInterned(ptr_info.child);
                const storage_class = self.spvStorageClass(ptr_info.flags.address_space);
                const ptr_ty_id = try self.ptrType(child_ty, storage_class, .indirect);

                if (ptr_info.flags.size != .slice) {
                    return ptr_ty_id;
                }

                const size_ty_id = try self.resolveType(Type.usize, .direct);
                const result_id = self.spv.allocId();
                try self.spv.structType(
                    result_id,
                    &.{ ptr_ty_id, size_ty_id },
                    &.{ "ptr", "len" },
                );
                return result_id;
            },
            .@"struct" => {
                const struct_type = switch (ip.indexToKey(ty.toIntern())) {
                    .tuple_type => |tuple| {
                        const member_types = try self.gpa.alloc(Id, tuple.values.len);
                        defer self.gpa.free(member_types);

                        var member_index: usize = 0;
                        for (tuple.types.get(ip), tuple.values.get(ip)) |field_ty, field_val| {
                            if (field_val != .none or !Type.fromInterned(field_ty).hasRuntimeBits(zcu)) continue;

                            member_types[member_index] = try self.resolveType(Type.fromInterned(field_ty), .indirect);
                            member_index += 1;
                        }

                        const result_id = self.spv.allocId();
                        try self.spv.structType(result_id, member_types[0..member_index], null);

                        const type_name = try self.resolveTypeName(ty);
                        defer self.gpa.free(type_name);
                        try self.spv.debugName(result_id, type_name);

                        return result_id;
                    },
                    .struct_type => ip.loadStructType(ty.toIntern()),
                    else => unreachable,
                };

                if (struct_type.layout == .@"packed") {
                    return try self.resolveType(Type.fromInterned(struct_type.backingIntTypeUnordered(ip)), .direct);
                }

                var member_types = std.ArrayList(Id).init(self.gpa);
                defer member_types.deinit();

                var member_names = std.ArrayList([]const u8).init(self.gpa);
                defer member_names.deinit();

                var index: u32 = 0;
                var it = struct_type.iterateRuntimeOrder(ip);
                const result_id = self.spv.allocId();
                while (it.next()) |field_index| {
                    const field_ty = Type.fromInterned(struct_type.field_types.get(ip)[field_index]);
                    if (!field_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                        // This is a zero-bit field - we only needed it for the alignment.
                        continue;
                    }

                    switch (self.spv.target.os.tag) {
                        .vulkan, .opengl => {
                            try self.spv.decorateMember(result_id, index, .{ .offset = .{
                                .byte_offset = @intCast(ty.structFieldOffset(field_index, zcu)),
                            } });
                        },
                        else => {},
                    }

                    const field_name = struct_type.fieldName(ip, field_index).unwrap() orelse
                        try ip.getOrPutStringFmt(zcu.gpa, pt.tid, "{d}", .{field_index}, .no_embedded_nulls);
                    try member_types.append(try self.resolveType(field_ty, .indirect));
                    try member_names.append(field_name.toSlice(ip));

                    index += 1;
                }

                try self.spv.structType(result_id, member_types.items, member_names.items);

                const type_name = try self.resolveTypeName(ty);
                defer self.gpa.free(type_name);
                try self.spv.debugName(result_id, type_name);

                return result_id;
            },
            .optional => {
                const payload_ty = ty.optionalChild(zcu);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                    // Just use a bool.
                    // Note: Always generate the bool with indirect format, to save on some sanity
                    // Perform the conversion to a direct bool when the field is extracted.
                    return try self.resolveType(Type.bool, .indirect);
                }

                const payload_ty_id = try self.resolveType(payload_ty, .indirect);
                if (ty.optionalReprIsPayload(zcu)) {
                    // Optional is actually a pointer or a slice.
                    return payload_ty_id;
                }

                const bool_ty_id = try self.resolveType(Type.bool, .indirect);

                const result_id = self.spv.allocId();
                try self.spv.structType(
                    result_id,
                    &.{ payload_ty_id, bool_ty_id },
                    &.{ "payload", "valid" },
                );
                return result_id;
            },
            .@"union" => return try self.resolveUnionType(ty),
            .error_set => {
                const err_int_ty = try pt.errorIntType();
                return try self.resolveType(err_int_ty, repr);
            },
            .error_union => {
                const payload_ty = ty.errorUnionPayload(zcu);
                const error_ty_id = try self.resolveType(Type.anyerror, .indirect);

                const eu_layout = self.errorUnionLayout(payload_ty);
                if (!eu_layout.payload_has_bits) {
                    return error_ty_id;
                }

                const payload_ty_id = try self.resolveType(payload_ty, .indirect);

                var member_types: [2]Id = undefined;
                var member_names: [2][]const u8 = undefined;
                if (eu_layout.error_first) {
                    // Put the error first
                    member_types = .{ error_ty_id, payload_ty_id };
                    member_names = .{ "error", "payload" };
                    // TODO: ABI padding?
                } else {
                    // Put the payload first.
                    member_types = .{ payload_ty_id, error_ty_id };
                    member_names = .{ "payload", "error" };
                    // TODO: ABI padding?
                }

                const result_id = self.spv.allocId();
                try self.spv.structType(result_id, &member_types, &member_names);
                return result_id;
            },
            .@"opaque" => {
                const type_name = try self.resolveTypeName(ty);
                defer self.gpa.free(type_name);

                const result_id = self.spv.allocId();
                try section.emit(self.spv.gpa, .OpTypeOpaque, .{
                    .id_result = result_id,
                    .literal_string = type_name,
                });
                return result_id;
            },

            .null,
            .undefined,
            .enum_literal,
            .comptime_float,
            .comptime_int,
            .type,
            => unreachable, // Must be comptime.

            .frame, .@"anyframe" => unreachable, // TODO
        }
    }

    fn spvStorageClass(self: *NavGen, as: std.builtin.AddressSpace) StorageClass {
        return switch (as) {
            .generic => if (self.spv.hasFeature(.generic_pointer)) .generic else .function,
            .global => switch (self.spv.target.os.tag) {
                .opencl, .amdhsa => .cross_workgroup,
                else => .storage_buffer,
            },
            .push_constant => {
                return .push_constant;
            },
            .output => {
                return .output;
            },
            .uniform => {
                return .uniform;
            },
            .storage_buffer => {
                return .storage_buffer;
            },
            .physical_storage_buffer => {
                return .physical_storage_buffer;
            },
            .constant => .uniform_constant,
            .shared => .workgroup,
            .local => .function,
            .input => .input,
            .gs,
            .fs,
            .ss,
            .param,
            .flash,
            .flash1,
            .flash2,
            .flash3,
            .flash4,
            .flash5,
            .cog,
            .lut,
            .hub,
            => unreachable,
        };
    }

    const ErrorUnionLayout = struct {
        payload_has_bits: bool,
        error_first: bool,

        fn errorFieldIndex(self: @This()) u32 {
            assert(self.payload_has_bits);
            return if (self.error_first) 0 else 1;
        }

        fn payloadFieldIndex(self: @This()) u32 {
            assert(self.payload_has_bits);
            return if (self.error_first) 1 else 0;
        }
    };

    fn errorUnionLayout(self: *NavGen, payload_ty: Type) ErrorUnionLayout {
        const pt = self.pt;
        const zcu = pt.zcu;

        const error_align = Type.anyerror.abiAlignment(zcu);
        const payload_align = payload_ty.abiAlignment(zcu);

        const error_first = error_align.compare(.gt, payload_align);
        return .{
            .payload_has_bits = payload_ty.hasRuntimeBitsIgnoreComptime(zcu),
            .error_first = error_first,
        };
    }

    const UnionLayout = struct {
        /// If false, this union is represented
        /// by only an integer of the tag type.
        has_payload: bool,
        tag_size: u32,
        tag_index: u32,
        /// Note: This is the size of the payload type itself, NOT the size of the ENTIRE payload.
        /// Use `has_payload` instead!!
        payload_ty: Type,
        payload_size: u32,
        payload_index: u32,
        payload_padding_size: u32,
        payload_padding_index: u32,
        padding_size: u32,
        padding_index: u32,
        total_fields: u32,
    };

    fn unionLayout(self: *NavGen, ty: Type) UnionLayout {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const layout = ty.unionGetLayout(zcu);
        const union_obj = zcu.typeToUnion(ty).?;

        var union_layout = UnionLayout{
            .has_payload = layout.payload_size != 0,
            .tag_size = @intCast(layout.tag_size),
            .tag_index = undefined,
            .payload_ty = undefined,
            .payload_size = undefined,
            .payload_index = undefined,
            .payload_padding_size = undefined,
            .payload_padding_index = undefined,
            .padding_size = @intCast(layout.padding),
            .padding_index = undefined,
            .total_fields = undefined,
        };

        if (union_layout.has_payload) {
            const most_aligned_field = layout.most_aligned_field;
            const most_aligned_field_ty = Type.fromInterned(union_obj.field_types.get(ip)[most_aligned_field]);
            union_layout.payload_ty = most_aligned_field_ty;
            union_layout.payload_size = @intCast(most_aligned_field_ty.abiSize(zcu));
        } else {
            union_layout.payload_size = 0;
        }

        union_layout.payload_padding_size = @intCast(layout.payload_size - union_layout.payload_size);

        const tag_first = layout.tag_align.compare(.gte, layout.payload_align);
        var field_index: u32 = 0;

        if (union_layout.tag_size != 0 and tag_first) {
            union_layout.tag_index = field_index;
            field_index += 1;
        }

        if (union_layout.payload_size != 0) {
            union_layout.payload_index = field_index;
            field_index += 1;
        }

        if (union_layout.payload_padding_size != 0) {
            union_layout.payload_padding_index = field_index;
            field_index += 1;
        }

        if (union_layout.tag_size != 0 and !tag_first) {
            union_layout.tag_index = field_index;
            field_index += 1;
        }

        if (union_layout.padding_size != 0) {
            union_layout.padding_index = field_index;
            field_index += 1;
        }

        union_layout.total_fields = field_index;

        return union_layout;
    }

    /// This structure represents a "temporary" value: Something we are currently
    /// operating on. It typically lives no longer than the function that
    /// implements a particular AIR operation. These are used to easier
    /// implement vectorizable operations (see Vectorization and the build*
    /// functions), and typically are only used for vectors of primitive types.
    const Temporary = struct {
        /// The type of the temporary. This is here mainly
        /// for easier bookkeeping. Because we will never really
        /// store Temporaries, they only cause extra stack space,
        /// therefore no real storage is wasted.
        ty: Type,
        /// The value that this temporary holds. This is not necessarily
        /// a value that is actually usable, or a single value: It is virtual
        /// until materialize() is called, at which point is turned into
        /// the usual SPIR-V representation of `self.ty`.
        value: Temporary.Value,

        const Value = union(enum) {
            singleton: Id,
            exploded_vector: IdRange,
        };

        fn init(ty: Type, singleton: Id) Temporary {
            return .{ .ty = ty, .value = .{ .singleton = singleton } };
        }

        fn materialize(self: Temporary, ng: *NavGen) !Id {
            const zcu = ng.pt.zcu;
            switch (self.value) {
                .singleton => |id| return id,
                .exploded_vector => |range| {
                    assert(self.ty.isVector(zcu));
                    assert(self.ty.vectorLen(zcu) == range.len);
                    const constituents = try ng.gpa.alloc(Id, range.len);
                    defer ng.gpa.free(constituents);
                    for (constituents, 0..range.len) |*id, i| {
                        id.* = range.at(i);
                    }
                    const result_ty_id = try ng.resolveType(self.ty, .direct);
                    return ng.constructComposite(result_ty_id, constituents);
                },
            }
        }

        fn vectorization(self: Temporary, ng: *NavGen) Vectorization {
            return Vectorization.fromType(self.ty, ng);
        }

        fn pun(self: Temporary, new_ty: Type) Temporary {
            return .{
                .ty = new_ty,
                .value = self.value,
            };
        }

        /// 'Explode' a temporary into separate elements. This turns a vector
        /// into a bag of elements.
        fn explode(self: Temporary, ng: *NavGen) !IdRange {
            const zcu = ng.pt.zcu;

            // If the value is a scalar, then this is a no-op.
            if (!self.ty.isVector(zcu)) {
                return switch (self.value) {
                    .singleton => |id| .{ .base = @intFromEnum(id), .len = 1 },
                    .exploded_vector => |range| range,
                };
            }

            const ty_id = try ng.resolveType(self.ty.scalarType(zcu), .direct);
            const n = self.ty.vectorLen(zcu);
            const results = ng.spv.allocIds(n);

            const id = switch (self.value) {
                .singleton => |id| id,
                .exploded_vector => |range| return range,
            };

            for (0..n) |i| {
                const indexes = [_]u32{@intCast(i)};
                try ng.func.body.emit(ng.spv.gpa, .OpCompositeExtract, .{
                    .id_result_type = ty_id,
                    .id_result = results.at(i),
                    .composite = id,
                    .indexes = &indexes,
                });
            }

            return results;
        }
    };

    /// Initialize a `Temporary` from an AIR value.
    fn temporary(self: *NavGen, inst: Air.Inst.Ref) !Temporary {
        return .{
            .ty = self.typeOf(inst),
            .value = .{ .singleton = try self.resolve(inst) },
        };
    }

    /// This union describes how a particular operation should be vectorized.
    /// That depends on the operation and number of components of the inputs.
    const Vectorization = union(enum) {
        /// This is an operation between scalars.
        scalar,
        /// This operation is unrolled into separate operations.
        /// Inputs may still be SPIR-V vectors, for example,
        /// when the operation can't be vectorized in SPIR-V.
        /// Value is number of components.
        unrolled: u32,

        /// Derive a vectorization from a particular type
        fn fromType(ty: Type, ng: *NavGen) Vectorization {
            const zcu = ng.pt.zcu;
            if (!ty.isVector(zcu)) return .scalar;
            return .{ .unrolled = ty.vectorLen(zcu) };
        }

        /// Given two vectorization methods, compute a "unification": a fallback
        /// that works for both, according to the following rules:
        /// - Scalars may broadcast
        /// - SPIR-V vectorized operations will unroll
        /// - Prefer scalar > unrolled
        fn unify(a: Vectorization, b: Vectorization) Vectorization {
            if (a == .scalar and b == .scalar) return .scalar;
            if (a == .unrolled or b == .unrolled) {
                if (a == .unrolled and b == .unrolled) assert(a.components() == b.components());
                if (a == .unrolled) return .{ .unrolled = a.components() };
                return .{ .unrolled = b.components() };
            }
            unreachable;
        }

        /// Query the number of components that inputs of this operation have.
        /// Note: for broadcasting scalars, this returns the number of elements
        /// that the broadcasted vector would have.
        fn components(self: Vectorization) u32 {
            return switch (self) {
                .scalar => 1,
                .unrolled => |n| n,
            };
        }

        /// Turns `ty` into the result-type of the entire operation.
        /// `ty` may be a scalar or vector, it doesn't matter.
        fn resultType(self: Vectorization, ng: *NavGen, ty: Type) !Type {
            const pt = ng.pt;
            const scalar_ty = ty.scalarType(pt.zcu);
            return switch (self) {
                .scalar => scalar_ty,
                .unrolled => |n| try pt.vectorType(.{ .len = n, .child = scalar_ty.toIntern() }),
            };
        }

        /// Before a temporary can be used, some setup may need to be one. This function implements
        /// this setup, and returns a new type that holds the relevant information on how to access
        /// elements of the input.
        fn prepare(self: Vectorization, ng: *NavGen, tmp: Temporary) !PreparedOperand {
            const pt = ng.pt;
            const is_vector = tmp.ty.isVector(pt.zcu);
            const value: PreparedOperand.Value = switch (tmp.value) {
                .singleton => |id| switch (self) {
                    .scalar => blk: {
                        assert(!is_vector);
                        break :blk .{ .scalar = id };
                    },
                    .unrolled => blk: {
                        if (is_vector) break :blk .{ .vector_exploded = try tmp.explode(ng) };
                        break :blk .{ .scalar_broadcast = id };
                    },
                },
                .exploded_vector => |range| switch (self) {
                    .scalar => unreachable,
                    .unrolled => |n| blk: {
                        assert(range.len == n);
                        break :blk .{ .vector_exploded = range };
                    },
                },
            };

            return .{
                .ty = tmp.ty,
                .value = value,
            };
        }

        /// Finalize the results of an operation back into a temporary. `results` is
        /// a list of result-ids of the operation.
        fn finalize(self: Vectorization, ty: Type, results: IdRange) Temporary {
            assert(self.components() == results.len);
            return .{
                .ty = ty,
                .value = switch (self) {
                    .scalar => .{ .singleton = results.at(0) },
                    .unrolled => .{ .exploded_vector = results },
                },
            };
        }

        /// This struct represents an operand that has gone through some setup, and is
        /// ready to be used as part of an operation.
        const PreparedOperand = struct {
            ty: Type,
            value: PreparedOperand.Value,

            /// The types of value that a prepared operand can hold internally. Depends
            /// on the operation and input value.
            const Value = union(enum) {
                /// A single scalar value that is used by a scalar operation.
                scalar: Id,
                /// A single scalar that is broadcasted in an unrolled operation.
                scalar_broadcast: Id,
                /// A vector represented by a consecutive list of IDs that is used in an unrolled operation.
                vector_exploded: IdRange,
            };

            /// Query the value at a particular index of the operation. Note that
            /// the index is *not* the component/lane, but the index of the *operation*.
            fn at(self: PreparedOperand, i: usize) Id {
                switch (self.value) {
                    .scalar => |id| {
                        assert(i == 0);
                        return id;
                    },
                    .scalar_broadcast => |id| return id,
                    .vector_exploded => |range| return range.at(i),
                }
            }
        };
    };

    /// A utility function to compute the vectorization style of
    /// a list of values. These values may be any of the following:
    /// - A `Vectorization` instance
    /// - A Type, in which case the vectorization is computed via `Vectorization.fromType`.
    /// - A Temporary, in which case the vectorization is computed via `Temporary.vectorization`.
    fn vectorization(self: *NavGen, args: anytype) Vectorization {
        var v: Vectorization = undefined;
        assert(args.len >= 1);
        inline for (args, 0..) |arg, i| {
            const iv: Vectorization = switch (@TypeOf(arg)) {
                Vectorization => arg,
                Type => Vectorization.fromType(arg, self),
                Temporary => arg.vectorization(self),
                else => @compileError("invalid type"),
            };
            if (i == 0) {
                v = iv;
            } else {
                v = v.unify(iv);
            }
        }
        return v;
    }

    /// This function builds an OpSConvert of OpUConvert depending on the
    /// signedness of the types.
    fn buildConvert(self: *NavGen, dst_ty: Type, src: Temporary) !Temporary {
        const zcu = self.pt.zcu;

        const dst_ty_id = try self.resolveType(dst_ty.scalarType(zcu), .direct);
        const src_ty_id = try self.resolveType(src.ty.scalarType(zcu), .direct);

        const v = self.vectorization(.{ dst_ty, src });
        const result_ty = try v.resultType(self, dst_ty);

        // We can directly compare integers, because those type-IDs are cached.
        if (dst_ty_id == src_ty_id) {
            // Nothing to do, type-pun to the right value.
            // Note, Caller guarantees that the types fit (or caller will normalize after),
            // so we don't have to normalize here.
            // Note, dst_ty may be a scalar type even if we expect a vector, so we have to
            // convert to the right type here.
            return src.pun(result_ty);
        }

        const ops = v.components();
        const results = self.spv.allocIds(ops);

        const op_result_ty = dst_ty.scalarType(zcu);
        const op_result_ty_id = try self.resolveType(op_result_ty, .direct);

        const opcode: Opcode = blk: {
            if (dst_ty.scalarType(zcu).isAnyFloat()) break :blk .OpFConvert;
            if (dst_ty.scalarType(zcu).isSignedInt(zcu)) break :blk .OpSConvert;
            break :blk .OpUConvert;
        };

        const op_src = try v.prepare(self, src);

        for (0..ops) |i| {
            try self.func.body.emitRaw(self.spv.gpa, opcode, 3);
            self.func.body.writeOperand(spec.Id, op_result_ty_id);
            self.func.body.writeOperand(Id, results.at(i));
            self.func.body.writeOperand(Id, op_src.at(i));
        }

        return v.finalize(result_ty, results);
    }

    fn buildFma(self: *NavGen, a: Temporary, b: Temporary, c: Temporary) !Temporary {
        const zcu = self.pt.zcu;
        const target = self.spv.target;

        const v = self.vectorization(.{ a, b, c });
        const ops = v.components();
        const results = self.spv.allocIds(ops);

        const op_result_ty = a.ty.scalarType(zcu);
        const op_result_ty_id = try self.resolveType(op_result_ty, .direct);
        const result_ty = try v.resultType(self, a.ty);

        const op_a = try v.prepare(self, a);
        const op_b = try v.prepare(self, b);
        const op_c = try v.prepare(self, c);

        const set = try self.importExtendedSet();

        // TODO: Put these numbers in some definition
        const instruction: u32 = switch (target.os.tag) {
            .opencl => 26, // fma
            // NOTE: Vulkan's FMA instruction does *NOT* produce the right values!
            //   its precision guarantees do NOT match zigs and it does NOT match OpenCLs!
            //   it needs to be emulated!
            .vulkan, .opengl => return self.todo("implement fma operation for {s} os", .{@tagName(target.os.tag)}),
            else => unreachable,
        };

        for (0..ops) |i| {
            try self.func.body.emit(self.spv.gpa, .OpExtInst, .{
                .id_result_type = op_result_ty_id,
                .id_result = results.at(i),
                .set = set,
                .instruction = .{ .inst = instruction },
                .id_ref_4 = &.{ op_a.at(i), op_b.at(i), op_c.at(i) },
            });
        }

        return v.finalize(result_ty, results);
    }

    fn buildSelect(self: *NavGen, condition: Temporary, lhs: Temporary, rhs: Temporary) !Temporary {
        const zcu = self.pt.zcu;

        const v = self.vectorization(.{ condition, lhs, rhs });
        const ops = v.components();
        const results = self.spv.allocIds(ops);

        const op_result_ty = lhs.ty.scalarType(zcu);
        const op_result_ty_id = try self.resolveType(op_result_ty, .direct);
        const result_ty = try v.resultType(self, lhs.ty);

        assert(condition.ty.scalarType(zcu).zigTypeTag(zcu) == .bool);

        const cond = try v.prepare(self, condition);
        const object_1 = try v.prepare(self, lhs);
        const object_2 = try v.prepare(self, rhs);

        for (0..ops) |i| {
            try self.func.body.emit(self.spv.gpa, .OpSelect, .{
                .id_result_type = op_result_ty_id,
                .id_result = results.at(i),
                .condition = cond.at(i),
                .object_1 = object_1.at(i),
                .object_2 = object_2.at(i),
            });
        }

        return v.finalize(result_ty, results);
    }

    const CmpPredicate = enum {
        l_eq,
        l_ne,
        i_ne,
        i_eq,
        s_lt,
        s_gt,
        s_le,
        s_ge,
        u_lt,
        u_gt,
        u_le,
        u_ge,
        f_oeq,
        f_une,
        f_olt,
        f_ole,
        f_ogt,
        f_oge,
    };

    fn buildCmp(self: *NavGen, pred: CmpPredicate, lhs: Temporary, rhs: Temporary) !Temporary {
        const v = self.vectorization(.{ lhs, rhs });
        const ops = v.components();
        const results = self.spv.allocIds(ops);

        const op_result_ty: Type = .bool;
        const op_result_ty_id = try self.resolveType(op_result_ty, .direct);
        const result_ty = try v.resultType(self, Type.bool);

        const op_lhs = try v.prepare(self, lhs);
        const op_rhs = try v.prepare(self, rhs);

        const opcode: Opcode = switch (pred) {
            .l_eq => .OpLogicalEqual,
            .l_ne => .OpLogicalNotEqual,
            .i_eq => .OpIEqual,
            .i_ne => .OpINotEqual,
            .s_lt => .OpSLessThan,
            .s_gt => .OpSGreaterThan,
            .s_le => .OpSLessThanEqual,
            .s_ge => .OpSGreaterThanEqual,
            .u_lt => .OpULessThan,
            .u_gt => .OpUGreaterThan,
            .u_le => .OpULessThanEqual,
            .u_ge => .OpUGreaterThanEqual,
            .f_oeq => .OpFOrdEqual,
            .f_une => .OpFUnordNotEqual,
            .f_olt => .OpFOrdLessThan,
            .f_ole => .OpFOrdLessThanEqual,
            .f_ogt => .OpFOrdGreaterThan,
            .f_oge => .OpFOrdGreaterThanEqual,
        };

        for (0..ops) |i| {
            try self.func.body.emitRaw(self.spv.gpa, opcode, 4);
            self.func.body.writeOperand(spec.Id, op_result_ty_id);
            self.func.body.writeOperand(Id, results.at(i));
            self.func.body.writeOperand(Id, op_lhs.at(i));
            self.func.body.writeOperand(Id, op_rhs.at(i));
        }

        return v.finalize(result_ty, results);
    }

    const UnaryOp = enum {
        l_not,
        bit_not,
        i_neg,
        f_neg,
        i_abs,
        f_abs,
        clz,
        ctz,
        floor,
        ceil,
        trunc,
        round,
        sqrt,
        sin,
        cos,
        tan,
        exp,
        exp2,
        log,
        log2,
        log10,
    };

    fn buildUnary(self: *NavGen, op: UnaryOp, operand: Temporary) !Temporary {
        const zcu = self.pt.zcu;
        const target = self.spv.target;
        const v = self.vectorization(.{operand});
        const ops = v.components();
        const results = self.spv.allocIds(ops);
        const op_result_ty = operand.ty.scalarType(zcu);
        const op_result_ty_id = try self.resolveType(op_result_ty, .direct);
        const result_ty = try v.resultType(self, operand.ty);

        const op_operand = try v.prepare(self, operand);

        if (switch (op) {
            .l_not => .OpLogicalNot,
            .bit_not => .OpNot,
            .i_neg => .OpSNegate,
            .f_neg => .OpFNegate,
            else => @as(?Opcode, null),
        }) |opcode| {
            for (0..ops) |i| {
                try self.func.body.emitRaw(self.spv.gpa, opcode, 3);
                self.func.body.writeOperand(spec.Id, op_result_ty_id);
                self.func.body.writeOperand(Id, results.at(i));
                self.func.body.writeOperand(Id, op_operand.at(i));
            }
        } else {
            const set = try self.importExtendedSet();
            const extinst: u32 = switch (target.os.tag) {
                .opencl => switch (op) {
                    .i_abs => 141, // s_abs
                    .f_abs => 23, // fabs
                    .clz => 151, // clz
                    .ctz => 152, // ctz
                    .floor => 25, // floor
                    .ceil => 12, // ceil
                    .trunc => 66, // trunc
                    .round => 55, // round
                    .sqrt => 61, // sqrt
                    .sin => 57, // sin
                    .cos => 14, // cos
                    .tan => 62, // tan
                    .exp => 19, // exp
                    .exp2 => 20, // exp2
                    .log => 37, // log
                    .log2 => 38, // log2
                    .log10 => 39, // log10
                    else => unreachable,
                },
                // Note: We'll need to check these for floating point accuracy
                // Vulkan does not put tight requirements on these, for correction
                // we might want to emulate them at some point.
                .vulkan, .opengl => switch (op) {
                    .i_abs => 5, // SAbs
                    .f_abs => 4, // FAbs
                    .floor => 8, // Floor
                    .ceil => 9, // Ceil
                    .trunc => 3, // Trunc
                    .round => 1, // Round
                    .clz,
                    .ctz,
                    .sqrt,
                    .sin,
                    .cos,
                    .tan,
                    .exp,
                    .exp2,
                    .log,
                    .log2,
                    .log10,
                    => return self.todo("implement unary operation '{s}' for {s} os", .{ @tagName(op), @tagName(target.os.tag) }),
                    else => unreachable,
                },
                else => unreachable,
            };

            for (0..ops) |i| {
                try self.func.body.emit(self.spv.gpa, .OpExtInst, .{
                    .id_result_type = op_result_ty_id,
                    .id_result = results.at(i),
                    .set = set,
                    .instruction = .{ .inst = extinst },
                    .id_ref_4 = &.{op_operand.at(i)},
                });
            }
        }

        return v.finalize(result_ty, results);
    }

    const BinaryOp = enum {
        i_add,
        f_add,
        i_sub,
        f_sub,
        i_mul,
        f_mul,
        s_div,
        u_div,
        f_div,
        s_rem,
        f_rem,
        s_mod,
        u_mod,
        f_mod,
        srl,
        sra,
        sll,
        bit_and,
        bit_or,
        bit_xor,
        f_max,
        s_max,
        u_max,
        f_min,
        s_min,
        u_min,
        l_and,
        l_or,
    };

    fn buildBinary(self: *NavGen, op: BinaryOp, lhs: Temporary, rhs: Temporary) !Temporary {
        const zcu = self.pt.zcu;
        const target = self.spv.target;

        const v = self.vectorization(.{ lhs, rhs });
        const ops = v.components();
        const results = self.spv.allocIds(ops);

        const op_result_ty = lhs.ty.scalarType(zcu);
        const op_result_ty_id = try self.resolveType(op_result_ty, .direct);
        const result_ty = try v.resultType(self, lhs.ty);

        const op_lhs = try v.prepare(self, lhs);
        const op_rhs = try v.prepare(self, rhs);

        if (switch (op) {
            .i_add => .OpIAdd,
            .f_add => .OpFAdd,
            .i_sub => .OpISub,
            .f_sub => .OpFSub,
            .i_mul => .OpIMul,
            .f_mul => .OpFMul,
            .s_div => .OpSDiv,
            .u_div => .OpUDiv,
            .f_div => .OpFDiv,
            .s_rem => .OpSRem,
            .f_rem => .OpFRem,
            .s_mod => .OpSMod,
            .u_mod => .OpUMod,
            .f_mod => .OpFMod,
            .srl => .OpShiftRightLogical,
            .sra => .OpShiftRightArithmetic,
            .sll => .OpShiftLeftLogical,
            .bit_and => .OpBitwiseAnd,
            .bit_or => .OpBitwiseOr,
            .bit_xor => .OpBitwiseXor,
            .l_and => .OpLogicalAnd,
            .l_or => .OpLogicalOr,
            else => @as(?Opcode, null),
        }) |opcode| {
            for (0..ops) |i| {
                try self.func.body.emitRaw(self.spv.gpa, opcode, 4);
                self.func.body.writeOperand(spec.Id, op_result_ty_id);
                self.func.body.writeOperand(Id, results.at(i));
                self.func.body.writeOperand(Id, op_lhs.at(i));
                self.func.body.writeOperand(Id, op_rhs.at(i));
            }
        } else {
            const set = try self.importExtendedSet();

            // TODO: Put these numbers in some definition
            const extinst: u32 = switch (target.os.tag) {
                .opencl => switch (op) {
                    .f_max => 27, // fmax
                    .s_max => 156, // s_max
                    .u_max => 157, // u_max
                    .f_min => 28, // fmin
                    .s_min => 158, // s_min
                    .u_min => 159, // u_min
                    else => unreachable,
                },
                .vulkan, .opengl => switch (op) {
                    .f_max => 40, // FMax
                    .s_max => 42, // SMax
                    .u_max => 41, // UMax
                    .f_min => 37, // FMin
                    .s_min => 39, // SMin
                    .u_min => 38, // UMin
                    else => unreachable,
                },
                else => unreachable,
            };

            for (0..ops) |i| {
                try self.func.body.emit(self.spv.gpa, .OpExtInst, .{
                    .id_result_type = op_result_ty_id,
                    .id_result = results.at(i),
                    .set = set,
                    .instruction = .{ .inst = extinst },
                    .id_ref_4 = &.{ op_lhs.at(i), op_rhs.at(i) },
                });
            }
        }

        return v.finalize(result_ty, results);
    }

    /// This function builds an extended multiplication, either OpSMulExtended or OpUMulExtended on Vulkan,
    /// or OpIMul and s_mul_hi or u_mul_hi on OpenCL.
    fn buildWideMul(
        self: *NavGen,
        op: enum {
            s_mul_extended,
            u_mul_extended,
        },
        lhs: Temporary,
        rhs: Temporary,
    ) !struct { Temporary, Temporary } {
        const pt = self.pt;
        const zcu = pt.zcu;
        const target = self.spv.target;
        const ip = &zcu.intern_pool;

        const v = lhs.vectorization(self).unify(rhs.vectorization(self));
        const ops = v.components();

        const arith_op_ty = lhs.ty.scalarType(zcu);
        const arith_op_ty_id = try self.resolveType(arith_op_ty, .direct);

        const lhs_op = try v.prepare(self, lhs);
        const rhs_op = try v.prepare(self, rhs);

        const value_results = self.spv.allocIds(ops);
        const overflow_results = self.spv.allocIds(ops);

        switch (target.os.tag) {
            .opencl => {
                // Currently, SPIRV-LLVM-Translator based backends cannot deal with OpSMulExtended and
                // OpUMulExtended. For these we will use the OpenCL s_mul_hi to compute the high-order bits
                // instead.
                const set = try self.importExtendedSet();
                const overflow_inst: u32 = switch (op) {
                    .s_mul_extended => 160, // s_mul_hi
                    .u_mul_extended => 203, // u_mul_hi
                };

                for (0..ops) |i| {
                    try self.func.body.emit(self.spv.gpa, .OpIMul, .{
                        .id_result_type = arith_op_ty_id,
                        .id_result = value_results.at(i),
                        .operand_1 = lhs_op.at(i),
                        .operand_2 = rhs_op.at(i),
                    });

                    try self.func.body.emit(self.spv.gpa, .OpExtInst, .{
                        .id_result_type = arith_op_ty_id,
                        .id_result = overflow_results.at(i),
                        .set = set,
                        .instruction = .{ .inst = overflow_inst },
                        .id_ref_4 = &.{ lhs_op.at(i), rhs_op.at(i) },
                    });
                }
            },
            .vulkan, .opengl => {
                // Operations return a struct{T, T}
                // where T is maybe vectorized.
                const op_result_ty: Type = .fromInterned(try ip.getTupleType(zcu.gpa, pt.tid, .{
                    .types = &.{ arith_op_ty.toIntern(), arith_op_ty.toIntern() },
                    .values = &.{ .none, .none },
                }));
                const op_result_ty_id = try self.resolveType(op_result_ty, .direct);

                const opcode: Opcode = switch (op) {
                    .s_mul_extended => .OpSMulExtended,
                    .u_mul_extended => .OpUMulExtended,
                };

                for (0..ops) |i| {
                    const op_result = self.spv.allocId();

                    try self.func.body.emitRaw(self.spv.gpa, opcode, 4);
                    self.func.body.writeOperand(spec.Id, op_result_ty_id);
                    self.func.body.writeOperand(Id, op_result);
                    self.func.body.writeOperand(Id, lhs_op.at(i));
                    self.func.body.writeOperand(Id, rhs_op.at(i));

                    // The above operation returns a struct. We might want to expand
                    // Temporary to deal with the fact that these are structs eventually,
                    // but for now, take the struct apart and return two separate vectors.

                    try self.func.body.emit(self.spv.gpa, .OpCompositeExtract, .{
                        .id_result_type = arith_op_ty_id,
                        .id_result = value_results.at(i),
                        .composite = op_result,
                        .indexes = &.{0},
                    });

                    try self.func.body.emit(self.spv.gpa, .OpCompositeExtract, .{
                        .id_result_type = arith_op_ty_id,
                        .id_result = overflow_results.at(i),
                        .composite = op_result,
                        .indexes = &.{1},
                    });
                }
            },
            else => unreachable,
        }

        const result_ty = try v.resultType(self, lhs.ty);
        return .{
            v.finalize(result_ty, value_results),
            v.finalize(result_ty, overflow_results),
        };
    }

    /// The SPIR-V backend is not yet advanced enough to support the std testing infrastructure.
    /// In order to be able to run tests, we "temporarily" lower test kernels into separate entry-
    /// points. The test executor will then be able to invoke these to run the tests.
    /// Note that tests are lowered according to std.builtin.TestFn, which is `fn () anyerror!void`.
    /// (anyerror!void has the same layout as anyerror).
    /// Each test declaration generates a function like.
    ///   %anyerror = OpTypeInt 0 16
    ///   %p_invocation_globals_struct_ty = ...
    ///   %p_anyerror = OpTypePointer CrossWorkgroup %anyerror
    ///   %K = OpTypeFunction %void %p_invocation_globals_struct_ty %p_anyerror
    ///
    ///   %test = OpFunction %void %K
    ///   %p_invocation_globals = OpFunctionParameter p_invocation_globals_struct_ty
    ///   %p_err = OpFunctionParameter %p_anyerror
    ///   %lbl = OpLabel
    ///   %result = OpFunctionCall %anyerror %func %p_invocation_globals
    ///   OpStore %p_err %result
    ///   OpFunctionEnd
    /// TODO is to also write out the error as a function call parameter, and to somehow fetch
    /// the name of an error in the text executor.
    fn generateTestEntryPoint(self: *NavGen, name: []const u8, spv_test_decl_index: SpvModule.Decl.Index) !void {
        const zcu = self.pt.zcu;
        const target = self.spv.target;

        const anyerror_ty_id = try self.resolveType(Type.anyerror, .direct);
        const ptr_anyerror_ty = try self.pt.ptrType(.{
            .child = Type.anyerror.toIntern(),
            .flags = .{ .address_space = .global },
        });
        const ptr_anyerror_ty_id = try self.resolveType(ptr_anyerror_ty, .direct);

        const spv_decl_index = try self.spv.allocDecl(.func);
        const kernel_id = self.spv.declPtr(spv_decl_index).result_id;

        var decl_deps = std.ArrayList(SpvModule.Decl.Index).init(self.gpa);
        defer decl_deps.deinit();
        try decl_deps.append(spv_test_decl_index);

        const section = &self.spv.sections.functions;

        const p_error_id = self.spv.allocId();
        switch (target.os.tag) {
            .opencl, .amdhsa => {
                const kernel_proto_ty_id = try self.functionType(Type.void, &.{ptr_anyerror_ty});

                try section.emit(self.spv.gpa, .OpFunction, .{
                    .id_result_type = try self.resolveType(Type.void, .direct),
                    .id_result = kernel_id,
                    .function_control = .{},
                    .function_type = kernel_proto_ty_id,
                });

                try section.emit(self.spv.gpa, .OpFunctionParameter, .{
                    .id_result_type = ptr_anyerror_ty_id,
                    .id_result = p_error_id,
                });

                try section.emit(self.spv.gpa, .OpLabel, .{
                    .id_result = self.spv.allocId(),
                });
            },
            .vulkan, .opengl => {
                if (self.object.error_buffer == null) {
                    const spv_err_decl_index = try self.spv.allocDecl(.global);
                    try self.spv.declareDeclDeps(spv_err_decl_index, &.{});

                    const buffer_struct_ty_id = self.spv.allocId();
                    try self.spv.structType(buffer_struct_ty_id, &.{anyerror_ty_id}, &.{"error_out"});
                    try self.spv.decorate(buffer_struct_ty_id, .block);
                    try self.spv.decorateMember(buffer_struct_ty_id, 0, .{ .offset = .{ .byte_offset = 0 } });

                    const ptr_buffer_struct_ty_id = self.spv.allocId();
                    try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpTypePointer, .{
                        .id_result = ptr_buffer_struct_ty_id,
                        .storage_class = self.spvStorageClass(.global),
                        .type = buffer_struct_ty_id,
                    });

                    const buffer_struct_id = self.spv.declPtr(spv_err_decl_index).result_id;
                    try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpVariable, .{
                        .id_result_type = ptr_buffer_struct_ty_id,
                        .id_result = buffer_struct_id,
                        .storage_class = self.spvStorageClass(.global),
                    });
                    try self.spv.decorate(buffer_struct_id, .{ .descriptor_set = .{ .descriptor_set = 0 } });
                    try self.spv.decorate(buffer_struct_id, .{ .binding = .{ .binding_point = 0 } });

                    self.object.error_buffer = spv_err_decl_index;
                }

                try self.spv.sections.execution_modes.emit(self.spv.gpa, .OpExecutionMode, .{
                    .entry_point = kernel_id,
                    .mode = .{ .local_size = .{
                        .x_size = 1,
                        .y_size = 1,
                        .z_size = 1,
                    } },
                });

                const kernel_proto_ty_id = try self.functionType(Type.void, &.{});
                try section.emit(self.spv.gpa, .OpFunction, .{
                    .id_result_type = try self.resolveType(Type.void, .direct),
                    .id_result = kernel_id,
                    .function_control = .{},
                    .function_type = kernel_proto_ty_id,
                });
                try section.emit(self.spv.gpa, .OpLabel, .{
                    .id_result = self.spv.allocId(),
                });

                const spv_err_decl_index = self.object.error_buffer.?;
                const buffer_id = self.spv.declPtr(spv_err_decl_index).result_id;
                try decl_deps.append(spv_err_decl_index);

                const zero_id = try self.constInt(Type.u32, 0);
                try section.emit(self.spv.gpa, .OpInBoundsAccessChain, .{
                    .id_result_type = ptr_anyerror_ty_id,
                    .id_result = p_error_id,
                    .base = buffer_id,
                    .indexes = &.{zero_id},
                });
            },
            else => unreachable,
        }

        const test_id = self.spv.declPtr(spv_test_decl_index).result_id;
        const error_id = self.spv.allocId();
        try section.emit(self.spv.gpa, .OpFunctionCall, .{
            .id_result_type = anyerror_ty_id,
            .id_result = error_id,
            .function = test_id,
        });
        // Note: Convert to direct not required.
        try section.emit(self.spv.gpa, .OpStore, .{
            .pointer = p_error_id,
            .object = error_id,
            .memory_access = .{
                .aligned = .{ .literal_integer = @intCast(Type.abiAlignment(.anyerror, zcu).toByteUnits().?) },
            },
        });
        try section.emit(self.spv.gpa, .OpReturn, {});
        try section.emit(self.spv.gpa, .OpFunctionEnd, {});

        // Just generate a quick other name because the intel runtime crashes when the entry-
        // point name is the same as a different OpName.
        const test_name = try std.fmt.allocPrint(self.gpa, "test {s}", .{name});
        defer self.gpa.free(test_name);

        const execution_mode: spec.ExecutionModel = switch (target.os.tag) {
            .vulkan, .opengl => .gl_compute,
            .opencl, .amdhsa => .kernel,
            else => unreachable,
        };

        try self.spv.declareDeclDeps(spv_decl_index, decl_deps.items);
        try self.spv.declareEntryPoint(spv_decl_index, test_name, execution_mode, null);
    }

    fn genNav(self: *NavGen, do_codegen: bool) !void {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;

        const nav = ip.getNav(self.owner_nav);
        const val = zcu.navValue(self.owner_nav);
        const ty = val.typeOf(zcu);

        if (!do_codegen and !ty.hasRuntimeBits(zcu)) {
            return;
        }

        const spv_decl_index = try self.object.resolveNav(zcu, self.owner_nav);
        const result_id = self.spv.declPtr(spv_decl_index).result_id;

        switch (self.spv.declPtr(spv_decl_index).kind) {
            .func => {
                const fn_info = zcu.typeToFunc(ty).?;
                const return_ty_id = try self.resolveFnReturnType(Type.fromInterned(fn_info.return_type));

                const prototype_ty_id = try self.resolveType(ty, .direct);
                try self.func.prologue.emit(self.spv.gpa, .OpFunction, .{
                    .id_result_type = return_ty_id,
                    .id_result = result_id,
                    .function_type = prototype_ty_id,
                    // Note: the backend will never be asked to generate an inline function
                    // (this is handled in sema), so we don't need to set function_control here.
                    .function_control = .{},
                });

                comptime assert(zig_call_abi_ver == 3);
                try self.args.ensureUnusedCapacity(self.gpa, fn_info.param_types.len);
                for (fn_info.param_types.get(ip)) |param_ty_index| {
                    const param_ty = Type.fromInterned(param_ty_index);
                    if (!param_ty.hasRuntimeBitsIgnoreComptime(zcu)) continue;

                    const param_type_id = try self.resolveType(param_ty, .direct);
                    const arg_result_id = self.spv.allocId();
                    try self.func.prologue.emit(self.spv.gpa, .OpFunctionParameter, .{
                        .id_result_type = param_type_id,
                        .id_result = arg_result_id,
                    });
                    self.args.appendAssumeCapacity(arg_result_id);
                }

                // TODO: This could probably be done in a better way...
                const root_block_id = self.spv.allocId();

                // The root block of a function declaration should appear before OpVariable instructions,
                // so it is generated into the function's prologue.
                try self.func.prologue.emit(self.spv.gpa, .OpLabel, .{
                    .id_result = root_block_id,
                });
                self.current_block_label = root_block_id;

                const main_body = self.air.getMainBody();
                switch (self.control_flow) {
                    .structured => {
                        _ = try self.genStructuredBody(.selection, main_body);
                        // We always expect paths to here to end, but we still need the block
                        // to act as a dummy merge block.
                        try self.func.body.emit(self.spv.gpa, .OpUnreachable, {});
                    },
                    .unstructured => {
                        try self.genBody(main_body);
                    },
                }
                try self.func.body.emit(self.spv.gpa, .OpFunctionEnd, {});
                // Append the actual code into the functions section.
                try self.spv.addFunction(spv_decl_index, self.func);

                try self.spv.debugName(result_id, nav.fqn.toSlice(ip));

                // Temporarily generate a test kernel declaration if this is a test function.
                if (self.pt.zcu.test_functions.contains(self.owner_nav)) {
                    try self.generateTestEntryPoint(nav.fqn.toSlice(ip), spv_decl_index);
                }
            },
            .global => {
                const maybe_init_val: ?Value = switch (ip.indexToKey(val.toIntern())) {
                    .func => unreachable,
                    .variable => |variable| Value.fromInterned(variable.init),
                    .@"extern" => null,
                    else => val,
                };
                assert(maybe_init_val == null); // TODO

                const storage_class = self.spvStorageClass(nav.getAddrspace());
                assert(storage_class != .generic); // These should be instance globals

                const ptr_ty_id = try self.ptrType(ty, storage_class, .indirect);

                try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpVariable, .{
                    .id_result_type = ptr_ty_id,
                    .id_result = result_id,
                    .storage_class = storage_class,
                });

                if (std.meta.stringToEnum(spec.BuiltIn, nav.fqn.toSlice(ip))) |builtin| {
                    try self.spv.decorate(result_id, .{ .built_in = .{ .built_in = builtin } });
                }

                try self.spv.debugName(result_id, nav.fqn.toSlice(ip));
                try self.spv.declareDeclDeps(spv_decl_index, &.{});
            },
            .invocation_global => {
                const maybe_init_val: ?Value = switch (ip.indexToKey(val.toIntern())) {
                    .func => unreachable,
                    .variable => |variable| Value.fromInterned(variable.init),
                    .@"extern" => null,
                    else => val,
                };

                try self.spv.declareDeclDeps(spv_decl_index, &.{});

                const ptr_ty_id = try self.ptrType(ty, .function, .indirect);

                if (maybe_init_val) |init_val| {
                    // TODO: Combine with resolveAnonDecl?
                    const initializer_proto_ty_id = try self.functionType(Type.void, &.{});

                    const initializer_id = self.spv.allocId();
                    try self.func.prologue.emit(self.spv.gpa, .OpFunction, .{
                        .id_result_type = try self.resolveType(Type.void, .direct),
                        .id_result = initializer_id,
                        .function_control = .{},
                        .function_type = initializer_proto_ty_id,
                    });

                    const root_block_id = self.spv.allocId();
                    try self.func.prologue.emit(self.spv.gpa, .OpLabel, .{
                        .id_result = root_block_id,
                    });
                    self.current_block_label = root_block_id;

                    const val_id = try self.constant(ty, init_val, .indirect);
                    try self.func.body.emit(self.spv.gpa, .OpStore, .{
                        .pointer = result_id,
                        .object = val_id,
                    });

                    try self.func.body.emit(self.spv.gpa, .OpReturn, {});
                    try self.func.body.emit(self.spv.gpa, .OpFunctionEnd, {});
                    try self.spv.addFunction(spv_decl_index, self.func);

                    try self.spv.debugNameFmt(initializer_id, "initializer of {f}", .{nav.fqn.fmt(ip)});

                    try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpExtInst, .{
                        .id_result_type = ptr_ty_id,
                        .id_result = result_id,
                        .set = try self.spv.importInstructionSet(.zig),
                        .instruction = .{ .inst = 0 }, // TODO: Put this definition somewhere...
                        .id_ref_4 = &.{initializer_id},
                    });
                } else {
                    try self.spv.sections.types_globals_constants.emit(self.spv.gpa, .OpExtInst, .{
                        .id_result_type = ptr_ty_id,
                        .id_result = result_id,
                        .set = try self.spv.importInstructionSet(.zig),
                        .instruction = .{ .inst = 0 }, // TODO: Put this definition somewhere...
                        .id_ref_4 = &.{},
                    });
                }
            },
        }
    }

    fn intFromBool(self: *NavGen, value: Temporary) !Temporary {
        return try self.intFromBool2(value, Type.u1);
    }

    fn intFromBool2(self: *NavGen, value: Temporary, result_ty: Type) !Temporary {
        const zero_id = try self.constInt(result_ty, 0);
        const one_id = try self.constInt(result_ty, 1);

        return try self.buildSelect(
            value,
            Temporary.init(result_ty, one_id),
            Temporary.init(result_ty, zero_id),
        );
    }

    /// Convert representation from indirect (in memory) to direct (in 'register')
    /// This converts the argument type from resolveType(ty, .indirect) to resolveType(ty, .direct).
    fn convertToDirect(self: *NavGen, ty: Type, operand_id: Id) !Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        switch (ty.scalarType(zcu).zigTypeTag(zcu)) {
            .bool => {
                const false_id = try self.constBool(false, .indirect);
                const operand_ty = blk: {
                    if (!ty.isVector(pt.zcu)) break :blk Type.u1;
                    break :blk try pt.vectorType(.{
                        .len = ty.vectorLen(pt.zcu),
                        .child = Type.u1.toIntern(),
                    });
                };

                const result = try self.buildCmp(
                    .i_ne,
                    Temporary.init(operand_ty, operand_id),
                    Temporary.init(Type.u1, false_id),
                );
                return try result.materialize(self);
            },
            else => return operand_id,
        }
    }

    /// Convert representation from direct (in 'register) to direct (in memory)
    /// This converts the argument type from resolveType(ty, .direct) to resolveType(ty, .indirect).
    fn convertToIndirect(self: *NavGen, ty: Type, operand_id: Id) !Id {
        const zcu = self.pt.zcu;
        switch (ty.scalarType(zcu).zigTypeTag(zcu)) {
            .bool => {
                const result = try self.intFromBool(Temporary.init(ty, operand_id));
                return try result.materialize(self);
            },
            else => return operand_id,
        }
    }

    fn extractField(self: *NavGen, result_ty: Type, object: Id, field: u32) !Id {
        const result_ty_id = try self.resolveType(result_ty, .indirect);
        const result_id = self.spv.allocId();
        const indexes = [_]u32{field};
        try self.func.body.emit(self.spv.gpa, .OpCompositeExtract, .{
            .id_result_type = result_ty_id,
            .id_result = result_id,
            .composite = object,
            .indexes = &indexes,
        });
        // Convert bools; direct structs have their field types as indirect values.
        return try self.convertToDirect(result_ty, result_id);
    }

    fn extractVectorComponent(self: *NavGen, result_ty: Type, vector_id: Id, field: u32) !Id {
        const result_ty_id = try self.resolveType(result_ty, .direct);
        const result_id = self.spv.allocId();
        const indexes = [_]u32{field};
        try self.func.body.emit(self.spv.gpa, .OpCompositeExtract, .{
            .id_result_type = result_ty_id,
            .id_result = result_id,
            .composite = vector_id,
            .indexes = &indexes,
        });
        // Vector components are already stored in direct representation.
        return result_id;
    }

    const MemoryOptions = struct {
        is_volatile: bool = false,
    };

    fn load(self: *NavGen, value_ty: Type, ptr_id: Id, options: MemoryOptions) !Id {
        const zcu = self.pt.zcu;
        const alignment: u32 = @intCast(value_ty.abiAlignment(zcu).toByteUnits().?);
        const indirect_value_ty_id = try self.resolveType(value_ty, .indirect);
        const result_id = self.spv.allocId();
        const access: spec.MemoryAccess.Extended = .{
            .@"volatile" = options.is_volatile,
            .aligned = .{ .literal_integer = alignment },
        };
        try self.func.body.emit(self.spv.gpa, .OpLoad, .{
            .id_result_type = indirect_value_ty_id,
            .id_result = result_id,
            .pointer = ptr_id,
            .memory_access = access,
        });
        return try self.convertToDirect(value_ty, result_id);
    }

    fn store(self: *NavGen, value_ty: Type, ptr_id: Id, value_id: Id, options: MemoryOptions) !void {
        const indirect_value_id = try self.convertToIndirect(value_ty, value_id);
        const access: spec.MemoryAccess.Extended = .{ .@"volatile" = options.is_volatile };
        try self.func.body.emit(self.spv.gpa, .OpStore, .{
            .pointer = ptr_id,
            .object = indirect_value_id,
            .memory_access = access,
        });
    }

    fn genBody(self: *NavGen, body: []const Air.Inst.Index) Error!void {
        for (body) |inst| {
            try self.genInst(inst);
        }
    }

    fn genInst(self: *NavGen, inst: Air.Inst.Index) !void {
        const zcu = self.pt.zcu;
        const ip = &zcu.intern_pool;
        if (self.liveness.isUnused(inst) and !self.air.mustLower(inst, ip))
            return;

        const air_tags = self.air.instructions.items(.tag);
        const maybe_result_id: ?Id = switch (air_tags[@intFromEnum(inst)]) {
            // zig fmt: off
            .add, .add_wrap, .add_optimized => try self.airArithOp(inst, .f_add, .i_add, .i_add),
            .sub, .sub_wrap, .sub_optimized => try self.airArithOp(inst, .f_sub, .i_sub, .i_sub),
            .mul, .mul_wrap, .mul_optimized => try self.airArithOp(inst, .f_mul, .i_mul, .i_mul),

            .sqrt => try self.airUnOpSimple(inst, .sqrt),
            .sin => try self.airUnOpSimple(inst, .sin),
            .cos => try self.airUnOpSimple(inst, .cos),
            .tan => try self.airUnOpSimple(inst, .tan),
            .exp => try self.airUnOpSimple(inst, .exp),
            .exp2 => try self.airUnOpSimple(inst, .exp2),
            .log => try self.airUnOpSimple(inst, .log),
            .log2 => try self.airUnOpSimple(inst, .log2),
            .log10 => try self.airUnOpSimple(inst, .log10),
            .abs => try self.airAbs(inst),
            .floor => try self.airUnOpSimple(inst, .floor),
            .ceil => try self.airUnOpSimple(inst, .ceil),
            .round => try self.airUnOpSimple(inst, .round),
            .trunc_float => try self.airUnOpSimple(inst, .trunc),
            .neg, .neg_optimized => try self.airUnOpSimple(inst, .f_neg),

            .div_float, .div_float_optimized => try self.airArithOp(inst, .f_div, .s_div, .u_div),
            .div_floor, .div_floor_optimized => try self.airDivFloor(inst),
            .div_trunc, .div_trunc_optimized => try self.airDivTrunc(inst),

            .rem, .rem_optimized => try self.airArithOp(inst, .f_rem, .s_rem, .u_mod),
            .mod, .mod_optimized => try self.airArithOp(inst, .f_mod, .s_mod, .u_mod),

            .add_with_overflow => try self.airAddSubOverflow(inst, .i_add, .u_lt, .s_lt),
            .sub_with_overflow => try self.airAddSubOverflow(inst, .i_sub, .u_gt, .s_gt),
            .mul_with_overflow => try self.airMulOverflow(inst),
            .shl_with_overflow => try self.airShlOverflow(inst),

            .mul_add => try self.airMulAdd(inst),

            .ctz => try self.airClzCtz(inst, .ctz),
            .clz => try self.airClzCtz(inst, .clz),

            .select => try self.airSelect(inst),

            .splat => try self.airSplat(inst),
            .reduce, .reduce_optimized => try self.airReduce(inst),
            .shuffle_one               => try self.airShuffleOne(inst),
            .shuffle_two               => try self.airShuffleTwo(inst),

            .ptr_add => try self.airPtrAdd(inst),
            .ptr_sub => try self.airPtrSub(inst),

            .bit_and  => try self.airBinOpSimple(inst, .bit_and),
            .bit_or   => try self.airBinOpSimple(inst, .bit_or),
            .xor      => try self.airBinOpSimple(inst, .bit_xor),
            .bool_and => try self.airBinOpSimple(inst, .l_and),
            .bool_or  => try self.airBinOpSimple(inst, .l_or),

            .shl, .shl_exact => try self.airShift(inst, .sll, .sll),
            .shr, .shr_exact => try self.airShift(inst, .srl, .sra),

            .min => try self.airMinMax(inst, .min),
            .max => try self.airMinMax(inst, .max),

            .bitcast         => try self.airBitCast(inst),
            .intcast, .trunc => try self.airIntCast(inst),
            .float_from_int  => try self.airFloatFromInt(inst),
            .int_from_float  => try self.airIntFromFloat(inst),
            .fpext, .fptrunc => try self.airFloatCast(inst),
            .not             => try self.airNot(inst),

            .array_to_slice => try self.airArrayToSlice(inst),
            .slice          => try self.airSlice(inst),
            .aggregate_init => try self.airAggregateInit(inst),
            .memcpy         => return self.airMemcpy(inst),
            .memmove        => return self.airMemmove(inst),

            .slice_ptr      => try self.airSliceField(inst, 0),
            .slice_len      => try self.airSliceField(inst, 1),
            .slice_elem_ptr => try self.airSliceElemPtr(inst),
            .slice_elem_val => try self.airSliceElemVal(inst),
            .ptr_elem_ptr   => try self.airPtrElemPtr(inst),
            .ptr_elem_val   => try self.airPtrElemVal(inst),
            .array_elem_val => try self.airArrayElemVal(inst),

            .vector_store_elem  => return self.airVectorStoreElem(inst),

            .set_union_tag => return self.airSetUnionTag(inst),
            .get_union_tag => try self.airGetUnionTag(inst),
            .union_init => try self.airUnionInit(inst),

            .struct_field_val => try self.airStructFieldVal(inst),
            .field_parent_ptr => try self.airFieldParentPtr(inst),

            .struct_field_ptr_index_0 => try self.airStructFieldPtrIndex(inst, 0),
            .struct_field_ptr_index_1 => try self.airStructFieldPtrIndex(inst, 1),
            .struct_field_ptr_index_2 => try self.airStructFieldPtrIndex(inst, 2),
            .struct_field_ptr_index_3 => try self.airStructFieldPtrIndex(inst, 3),

            .cmp_eq     => try self.airCmp(inst, .eq),
            .cmp_neq    => try self.airCmp(inst, .neq),
            .cmp_gt     => try self.airCmp(inst, .gt),
            .cmp_gte    => try self.airCmp(inst, .gte),
            .cmp_lt     => try self.airCmp(inst, .lt),
            .cmp_lte    => try self.airCmp(inst, .lte),
            .cmp_vector => try self.airVectorCmp(inst),

            .arg     => self.airArg(),
            .alloc   => try self.airAlloc(inst),
            // TODO: We probably need to have a special implementation of this for the C abi.
            .ret_ptr => try self.airAlloc(inst),
            .block   => try self.airBlock(inst),

            .load               => try self.airLoad(inst),
            .store, .store_safe => return self.airStore(inst),

            .br             => return self.airBr(inst),
            // For now just ignore this instruction. This effectively falls back on the old implementation,
            // this doesn't change anything for us.
            .repeat         => return,
            .breakpoint     => return,
            .cond_br        => return self.airCondBr(inst),
            .loop           => return self.airLoop(inst),
            .ret            => return self.airRet(inst),
            .ret_safe       => return self.airRet(inst), // TODO
            .ret_load       => return self.airRetLoad(inst),
            .@"try"         => try self.airTry(inst),
            .switch_br      => return self.airSwitchBr(inst),
            .unreach, .trap => return self.airUnreach(),

            .dbg_empty_stmt            => return,
            .dbg_stmt                  => return self.airDbgStmt(inst),
            .dbg_inline_block          => try self.airDbgInlineBlock(inst),
            .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => return self.airDbgVar(inst),

            .unwrap_errunion_err => try self.airErrUnionErr(inst),
            .unwrap_errunion_payload => try self.airErrUnionPayload(inst),
            .wrap_errunion_err => try self.airWrapErrUnionErr(inst),
            .wrap_errunion_payload => try self.airWrapErrUnionPayload(inst),

            .is_null         => try self.airIsNull(inst, false, .is_null),
            .is_non_null     => try self.airIsNull(inst, false, .is_non_null),
            .is_null_ptr     => try self.airIsNull(inst, true, .is_null),
            .is_non_null_ptr => try self.airIsNull(inst, true, .is_non_null),
            .is_err          => try self.airIsErr(inst, .is_err),
            .is_non_err      => try self.airIsErr(inst, .is_non_err),

            .optional_payload     => try self.airUnwrapOptional(inst),
            .optional_payload_ptr => try self.airUnwrapOptionalPtr(inst),
            .wrap_optional        => try self.airWrapOptional(inst),

            .assembly => try self.airAssembly(inst),

            .call              => try self.airCall(inst, .auto),
            .call_always_tail  => try self.airCall(inst, .always_tail),
            .call_never_tail   => try self.airCall(inst, .never_tail),
            .call_never_inline => try self.airCall(inst, .never_inline),

            .work_item_id => try self.airWorkItemId(inst),
            .work_group_size => try self.airWorkGroupSize(inst),
            .work_group_id => try self.airWorkGroupId(inst),

            // zig fmt: on

            else => |tag| return self.todo("implement AIR tag {s}", .{@tagName(tag)}),
        };

        const result_id = maybe_result_id orelse return;
        try self.inst_results.putNoClobber(self.gpa, inst, result_id);
    }

    fn airBinOpSimple(self: *NavGen, inst: Air.Inst.Index, op: BinaryOp) !?Id {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const lhs = try self.temporary(bin_op.lhs);
        const rhs = try self.temporary(bin_op.rhs);

        const result = try self.buildBinary(op, lhs, rhs);
        return try result.materialize(self);
    }

    fn airShift(self: *NavGen, inst: Air.Inst.Index, unsigned: BinaryOp, signed: BinaryOp) !?Id {
        const zcu = self.pt.zcu;
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

        if (self.typeOf(bin_op.lhs).isVector(zcu) and !self.typeOf(bin_op.rhs).isVector(zcu)) {
            return self.fail("vector shift with scalar rhs", .{});
        }

        const base = try self.temporary(bin_op.lhs);
        const shift = try self.temporary(bin_op.rhs);

        const result_ty = self.typeOfIndex(inst);

        const info = self.arithmeticTypeInfo(result_ty);
        switch (info.class) {
            .composite_integer => return self.todo("shift ops for composite integers", .{}),
            .integer, .strange_integer => {},
            .float, .bool => unreachable,
        }

        // Sometimes Zig doesn't make both of the arguments the same types here. SPIR-V expects that,
        // so just manually upcast it if required.

        // Note: The sign may differ here between the shift and the base type, in case
        // of an arithmetic right shift. SPIR-V still expects the same type,
        // so in that case we have to cast convert to signed.
        const casted_shift = try self.buildConvert(base.ty.scalarType(zcu), shift);

        const shifted = switch (info.signedness) {
            .unsigned => try self.buildBinary(unsigned, base, casted_shift),
            .signed => try self.buildBinary(signed, base, casted_shift),
        };

        const result = try self.normalize(shifted, info);
        return try result.materialize(self);
    }

    const MinMax = enum { min, max };

    fn airMinMax(self: *NavGen, inst: Air.Inst.Index, op: MinMax) !?Id {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

        const lhs = try self.temporary(bin_op.lhs);
        const rhs = try self.temporary(bin_op.rhs);

        const result = try self.minMax(lhs, rhs, op);
        return try result.materialize(self);
    }

    fn minMax(self: *NavGen, lhs: Temporary, rhs: Temporary, op: MinMax) !Temporary {
        const info = self.arithmeticTypeInfo(lhs.ty);

        const binop: BinaryOp = switch (info.class) {
            .float => switch (op) {
                .min => .f_min,
                .max => .f_max,
            },
            .integer, .strange_integer => switch (info.signedness) {
                .signed => switch (op) {
                    .min => .s_min,
                    .max => .s_max,
                },
                .unsigned => switch (op) {
                    .min => .u_min,
                    .max => .u_max,
                },
            },
            .composite_integer => unreachable, // TODO
            .bool => unreachable,
        };

        return try self.buildBinary(binop, lhs, rhs);
    }

    /// This function normalizes values to a canonical representation
    /// after some arithmetic operation. This mostly consists of wrapping
    /// behavior for strange integers:
    /// - Unsigned integers are bitwise masked with a mask that only passes
    ///   the valid bits through.
    /// - Signed integers are also sign extended if they are negative.
    /// All other values are returned unmodified (this makes strange integer
    /// wrapping easier to use in generic operations).
    fn normalize(self: *NavGen, value: Temporary, info: ArithmeticTypeInfo) !Temporary {
        const zcu = self.pt.zcu;
        const ty = value.ty;
        switch (info.class) {
            .composite_integer, .integer, .bool, .float => return value,
            .strange_integer => switch (info.signedness) {
                .unsigned => {
                    const mask_value = if (info.bits == 64) 0xFFFF_FFFF_FFFF_FFFF else (@as(u64, 1) << @as(u6, @intCast(info.bits))) - 1;
                    const mask_id = try self.constInt(ty.scalarType(zcu), mask_value);
                    return try self.buildBinary(.bit_and, value, Temporary.init(ty.scalarType(zcu), mask_id));
                },
                .signed => {
                    // Shift left and right so that we can copy the sight bit that way.
                    const shift_amt_id = try self.constInt(ty.scalarType(zcu), info.backing_bits - info.bits);
                    const shift_amt = Temporary.init(ty.scalarType(zcu), shift_amt_id);
                    const left = try self.buildBinary(.sll, value, shift_amt);
                    return try self.buildBinary(.sra, left, shift_amt);
                },
            },
        }
    }

    fn airDivFloor(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

        const lhs = try self.temporary(bin_op.lhs);
        const rhs = try self.temporary(bin_op.rhs);

        const info = self.arithmeticTypeInfo(lhs.ty);
        switch (info.class) {
            .composite_integer => unreachable, // TODO
            .integer, .strange_integer => {
                switch (info.signedness) {
                    .unsigned => {
                        const result = try self.buildBinary(.u_div, lhs, rhs);
                        return try result.materialize(self);
                    },
                    .signed => {},
                }

                // For signed integers:
                //   (a / b) - (a % b != 0 && a < 0 != b < 0);
                // There shouldn't be any overflow issues.

                const div = try self.buildBinary(.s_div, lhs, rhs);
                const rem = try self.buildBinary(.s_rem, lhs, rhs);

                const zero = Temporary.init(lhs.ty, try self.constInt(lhs.ty, 0));

                const rem_is_not_zero = try self.buildCmp(.i_ne, rem, zero);

                const result_negative = try self.buildCmp(
                    .l_ne,
                    try self.buildCmp(.s_lt, lhs, zero),
                    try self.buildCmp(.s_lt, rhs, zero),
                );
                const rem_is_not_zero_and_result_is_negative = try self.buildBinary(
                    .l_and,
                    rem_is_not_zero,
                    result_negative,
                );

                const result = try self.buildBinary(
                    .i_sub,
                    div,
                    try self.intFromBool2(rem_is_not_zero_and_result_is_negative, div.ty),
                );

                return try result.materialize(self);
            },
            .float => {
                const div = try self.buildBinary(.f_div, lhs, rhs);
                const result = try self.buildUnary(.floor, div);
                return try result.materialize(self);
            },
            .bool => unreachable,
        }
    }

    fn airDivTrunc(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

        const lhs = try self.temporary(bin_op.lhs);
        const rhs = try self.temporary(bin_op.rhs);

        const info = self.arithmeticTypeInfo(lhs.ty);
        switch (info.class) {
            .composite_integer => unreachable, // TODO
            .integer, .strange_integer => switch (info.signedness) {
                .unsigned => {
                    const result = try self.buildBinary(.u_div, lhs, rhs);
                    return try result.materialize(self);
                },
                .signed => {
                    const result = try self.buildBinary(.s_div, lhs, rhs);
                    return try result.materialize(self);
                },
            },
            .float => {
                const div = try self.buildBinary(.f_div, lhs, rhs);
                const result = try self.buildUnary(.trunc, div);
                return try result.materialize(self);
            },
            .bool => unreachable,
        }
    }

    fn airUnOpSimple(self: *NavGen, inst: Air.Inst.Index, op: UnaryOp) !?Id {
        const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
        const operand = try self.temporary(un_op);
        const result = try self.buildUnary(op, operand);
        return try result.materialize(self);
    }

    fn airArithOp(
        self: *NavGen,
        inst: Air.Inst.Index,
        comptime fop: BinaryOp,
        comptime sop: BinaryOp,
        comptime uop: BinaryOp,
    ) !?Id {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;

        const lhs = try self.temporary(bin_op.lhs);
        const rhs = try self.temporary(bin_op.rhs);

        const info = self.arithmeticTypeInfo(lhs.ty);

        const result = switch (info.class) {
            .composite_integer => unreachable, // TODO
            .integer, .strange_integer => switch (info.signedness) {
                .signed => try self.buildBinary(sop, lhs, rhs),
                .unsigned => try self.buildBinary(uop, lhs, rhs),
            },
            .float => try self.buildBinary(fop, lhs, rhs),
            .bool => unreachable,
        };

        return try result.materialize(self);
    }

    fn airAbs(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand = try self.temporary(ty_op.operand);
        // Note: operand_ty may be signed, while ty is always unsigned!
        const result_ty = self.typeOfIndex(inst);
        const result = try self.abs(result_ty, operand);
        return try result.materialize(self);
    }

    fn abs(self: *NavGen, result_ty: Type, value: Temporary) !Temporary {
        const zcu = self.pt.zcu;
        const operand_info = self.arithmeticTypeInfo(value.ty);

        switch (operand_info.class) {
            .float => return try self.buildUnary(.f_abs, value),
            .integer, .strange_integer => {
                const abs_value = try self.buildUnary(.i_abs, value);

                switch (self.spv.target.os.tag) {
                    .vulkan, .opengl => {
                        if (value.ty.intInfo(zcu).signedness == .signed) {
                            return self.todo("perform bitcast after @abs", .{});
                        }
                    },
                    else => {},
                }

                return try self.normalize(abs_value, self.arithmeticTypeInfo(result_ty));
            },
            .composite_integer => unreachable, // TODO
            .bool => unreachable,
        }
    }

    fn airAddSubOverflow(
        self: *NavGen,
        inst: Air.Inst.Index,
        comptime add: BinaryOp,
        comptime ucmp: CmpPredicate,
        comptime scmp: CmpPredicate,
    ) !?Id {
        _ = scmp;
        // Note: OpIAddCarry and OpISubBorrow are not really useful here: For unsigned numbers,
        // there is in both cases only one extra operation required. For signed operations,
        // the overflow bit is set then going from 0x80.. to 0x00.., but this doesn't actually
        // normally set a carry bit. So the SPIR-V overflow operations are not particularly
        // useful here.

        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;

        const lhs = try self.temporary(extra.lhs);
        const rhs = try self.temporary(extra.rhs);

        const result_ty = self.typeOfIndex(inst);

        const info = self.arithmeticTypeInfo(lhs.ty);
        switch (info.class) {
            .composite_integer => unreachable, // TODO
            .strange_integer, .integer => {},
            .float, .bool => unreachable,
        }

        const sum = try self.buildBinary(add, lhs, rhs);
        const result = try self.normalize(sum, info);

        const overflowed = switch (info.signedness) {
            // Overflow happened if the result is smaller than either of the operands. It doesn't matter which.
            // For subtraction the conditions need to be swapped.
            .unsigned => try self.buildCmp(ucmp, result, lhs),
            // For signed operations, we check the signs of the operands and the result.
            .signed => blk: {
                // Signed overflow detection using the sign bits of the operands and the result.
                // For addition (a + b), overflow occurs if the operands have the same sign
                // and the result's sign is different from the operands' sign.
                //   (sign(a) == sign(b)) && (sign(a) != sign(result))
                // For subtraction (a - b), overflow occurs if the operands have different signs
                // and the result's sign is different from the minuend's (a's) sign.
                //   (sign(a) != sign(b)) && (sign(a) != sign(result))
                const zero = Temporary.init(rhs.ty, try self.constInt(rhs.ty, 0));

                const lhs_is_neg = try self.buildCmp(.s_lt, lhs, zero);
                const rhs_is_neg = try self.buildCmp(.s_lt, rhs, zero);
                const result_is_neg = try self.buildCmp(.s_lt, result, zero);

                const signs_match = try self.buildCmp(.l_eq, lhs_is_neg, rhs_is_neg);
                const result_sign_differs = try self.buildCmp(.l_ne, lhs_is_neg, result_is_neg);

                const overflow_condition = if (add == .i_add)
                    signs_match
                else // .i_sub
                    try self.buildUnary(.l_not, signs_match);

                break :blk try self.buildBinary(.l_and, overflow_condition, result_sign_differs);
            },
        };

        const ov = try self.intFromBool(overflowed);

        const result_ty_id = try self.resolveType(result_ty, .direct);
        return try self.constructComposite(result_ty_id, &.{ try result.materialize(self), try ov.materialize(self) });
    }

    fn airMulOverflow(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;

        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;

        const lhs = try self.temporary(extra.lhs);
        const rhs = try self.temporary(extra.rhs);

        const result_ty = self.typeOfIndex(inst);

        const info = self.arithmeticTypeInfo(lhs.ty);
        switch (info.class) {
            .composite_integer => unreachable, // TODO
            .strange_integer, .integer => {},
            .float, .bool => unreachable,
        }

        // There are 3 cases which we have to deal with:
        // - If info.bits < 32 / 2, we will upcast to 32 and check the higher bits
        // - If info.bits > 32 / 2, we have to use extended multiplication
        // - Additionally, if info.bits != 32, we'll have to check the high bits
        //   of the result too.

        const largest_int_bits = self.largestSupportedIntBits();
        // If non-null, the number of bits that the multiplication should be performed in. If
        // null, we have to use wide multiplication.
        const maybe_op_ty_bits: ?u16 = switch (info.bits) {
            0 => unreachable,
            1...16 => 32,
            17...32 => if (largest_int_bits > 32) 64 else null, // Upcast if we can.
            33...64 => null, // Always use wide multiplication.
            else => unreachable, // TODO: Composite integers
        };

        const result, const overflowed = switch (info.signedness) {
            .unsigned => blk: {
                if (maybe_op_ty_bits) |op_ty_bits| {
                    const op_ty = try pt.intType(.unsigned, op_ty_bits);
                    const casted_lhs = try self.buildConvert(op_ty, lhs);
                    const casted_rhs = try self.buildConvert(op_ty, rhs);

                    const full_result = try self.buildBinary(.i_mul, casted_lhs, casted_rhs);

                    const low_bits = try self.buildConvert(lhs.ty, full_result);
                    const result = try self.normalize(low_bits, info);

                    // Shift the result bits away to get the overflow bits.
                    const shift = Temporary.init(full_result.ty, try self.constInt(full_result.ty, info.bits));
                    const overflow = try self.buildBinary(.srl, full_result, shift);

                    // Directly check if its zero in the op_ty without converting first.
                    const zero = Temporary.init(full_result.ty, try self.constInt(full_result.ty, 0));
                    const overflowed = try self.buildCmp(.i_ne, zero, overflow);

                    break :blk .{ result, overflowed };
                }

                const low_bits, const high_bits = try self.buildWideMul(.u_mul_extended, lhs, rhs);

                // Truncate the result, if required.
                const result = try self.normalize(low_bits, info);

                // Overflow happened if the high-bits of the result are non-zero OR if the
                // high bits of the low word of the result (those outside the range of the
                // int) are nonzero.
                const zero = Temporary.init(lhs.ty, try self.constInt(lhs.ty, 0));
                const high_overflowed = try self.buildCmp(.i_ne, zero, high_bits);

                // If no overflow bits in low_bits, no extra work needs to be done.
                if (info.backing_bits == info.bits) break :blk .{ result, high_overflowed };

                // Shift the result bits away to get the overflow bits.
                const shift = Temporary.init(lhs.ty, try self.constInt(lhs.ty, info.bits));
                const low_overflow = try self.buildBinary(.srl, low_bits, shift);
                const low_overflowed = try self.buildCmp(.i_ne, zero, low_overflow);

                const overflowed = try self.buildBinary(.l_or, low_overflowed, high_overflowed);

                break :blk .{ result, overflowed };
            },
            .signed => blk: {
                // - lhs >= 0, rhxs >= 0: expect positive; overflow should be  0
                // - lhs == 0          : expect positive; overflow should be  0
                // -           rhs == 0: expect positive; overflow should be  0
                // - lhs  > 0, rhs  < 0: expect negative; overflow should be -1
                // - lhs  < 0, rhs  > 0: expect negative; overflow should be -1
                // - lhs <= 0, rhs <= 0: expect positive; overflow should be  0
                // ------
                // overflow should be -1 when
                //   (lhs > 0 && rhs < 0) || (lhs < 0 && rhs > 0)

                const zero = Temporary.init(lhs.ty, try self.constInt(lhs.ty, 0));
                const lhs_negative = try self.buildCmp(.s_lt, lhs, zero);
                const rhs_negative = try self.buildCmp(.s_lt, rhs, zero);
                const lhs_positive = try self.buildCmp(.s_gt, lhs, zero);
                const rhs_positive = try self.buildCmp(.s_gt, rhs, zero);

                // Set to `true` if we expect -1.
                const expected_overflow_bit = try self.buildBinary(
                    .l_or,
                    try self.buildBinary(.l_and, lhs_positive, rhs_negative),
                    try self.buildBinary(.l_and, lhs_negative, rhs_positive),
                );

                if (maybe_op_ty_bits) |op_ty_bits| {
                    const op_ty = try pt.intType(.signed, op_ty_bits);
                    // Assume normalized; sign bit is set. We want a sign extend.
                    const casted_lhs = try self.buildConvert(op_ty, lhs);
                    const casted_rhs = try self.buildConvert(op_ty, rhs);

                    const full_result = try self.buildBinary(.i_mul, casted_lhs, casted_rhs);

                    // Truncate to the result type.
                    const low_bits = try self.buildConvert(lhs.ty, full_result);
                    const result = try self.normalize(low_bits, info);

                    // Now, we need to check the overflow bits AND the sign
                    // bit for the expected overflow bits.
                    // To do that, shift out everything bit the sign bit and
                    // then check what remains.
                    const shift = Temporary.init(full_result.ty, try self.constInt(full_result.ty, info.bits - 1));
                    // Use SRA so that any sign bits are duplicated. Now we can just check if ALL bits are set
                    // for negative cases.
                    const overflow = try self.buildBinary(.sra, full_result, shift);

                    const long_all_set = Temporary.init(full_result.ty, try self.constInt(full_result.ty, -1));
                    const long_zero = Temporary.init(full_result.ty, try self.constInt(full_result.ty, 0));
                    const mask = try self.buildSelect(expected_overflow_bit, long_all_set, long_zero);

                    const overflowed = try self.buildCmp(.i_ne, mask, overflow);

                    break :blk .{ result, overflowed };
                }

                const low_bits, const high_bits = try self.buildWideMul(.s_mul_extended, lhs, rhs);

                // Truncate result if required.
                const result = try self.normalize(low_bits, info);

                const all_set = Temporary.init(lhs.ty, try self.constInt(lhs.ty, -1));
                const mask = try self.buildSelect(expected_overflow_bit, all_set, zero);

                // Like with unsigned, overflow happened if high_bits are not the ones we expect,
                // and we also need to check some ones from the low bits.

                const high_overflowed = try self.buildCmp(.i_ne, mask, high_bits);

                // If no overflow bits in low_bits, no extra work needs to be done.
                // Careful, we still have to check the sign bit, so this branch
                // only goes for i33 and such.
                if (info.backing_bits == info.bits + 1) break :blk .{ result, high_overflowed };

                // Shift the result bits away to get the overflow bits.
                const shift = Temporary.init(lhs.ty, try self.constInt(lhs.ty, info.bits - 1));
                // Use SRA so that any sign bits are duplicated. Now we can just check if ALL bits are set
                // for negative cases.
                const low_overflow = try self.buildBinary(.sra, low_bits, shift);
                const low_overflowed = try self.buildCmp(.i_ne, mask, low_overflow);

                const overflowed = try self.buildBinary(.l_or, low_overflowed, high_overflowed);

                break :blk .{ result, overflowed };
            },
        };

        const ov = try self.intFromBool(overflowed);

        const result_ty_id = try self.resolveType(result_ty, .direct);
        return try self.constructComposite(result_ty_id, &.{ try result.materialize(self), try ov.materialize(self) });
    }

    fn airShlOverflow(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;

        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;

        if (self.typeOf(extra.lhs).isVector(zcu) and !self.typeOf(extra.rhs).isVector(zcu)) {
            return self.fail("vector shift with scalar rhs", .{});
        }

        const base = try self.temporary(extra.lhs);
        const shift = try self.temporary(extra.rhs);

        const result_ty = self.typeOfIndex(inst);

        const info = self.arithmeticTypeInfo(base.ty);
        switch (info.class) {
            .composite_integer => unreachable, // TODO
            .integer, .strange_integer => {},
            .float, .bool => unreachable,
        }

        // Sometimes Zig doesn't make both of the arguments the same types here. SPIR-V expects that,
        // so just manually upcast it if required.
        const casted_shift = try self.buildConvert(base.ty.scalarType(zcu), shift);

        const left = try self.buildBinary(.sll, base, casted_shift);
        const result = try self.normalize(left, info);

        const right = switch (info.signedness) {
            .unsigned => try self.buildBinary(.srl, result, casted_shift),
            .signed => try self.buildBinary(.sra, result, casted_shift),
        };

        const overflowed = try self.buildCmp(.i_ne, base, right);
        const ov = try self.intFromBool(overflowed);

        const result_ty_id = try self.resolveType(result_ty, .direct);
        return try self.constructComposite(result_ty_id, &.{ try result.materialize(self), try ov.materialize(self) });
    }

    fn airMulAdd(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const extra = self.air.extraData(Air.Bin, pl_op.payload).data;

        const a = try self.temporary(extra.lhs);
        const b = try self.temporary(extra.rhs);
        const c = try self.temporary(pl_op.operand);

        const result_ty = self.typeOfIndex(inst);
        const info = self.arithmeticTypeInfo(result_ty);
        assert(info.class == .float); // .mul_add is only emitted for floats

        const result = try self.buildFma(a, b, c);
        return try result.materialize(self);
    }

    fn airClzCtz(self: *NavGen, inst: Air.Inst.Index, op: UnaryOp) !?Id {
        if (self.liveness.isUnused(inst)) return null;

        const zcu = self.pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand = try self.temporary(ty_op.operand);

        const scalar_result_ty = self.typeOfIndex(inst).scalarType(zcu);

        const info = self.arithmeticTypeInfo(operand.ty);
        switch (info.class) {
            .composite_integer => unreachable, // TODO
            .integer, .strange_integer => {},
            .float, .bool => unreachable,
        }

        const count = try self.buildUnary(op, operand);

        // Result of OpenCL ctz/clz returns operand.ty, and we want result_ty.
        // result_ty is always large enough to hold the result, so we might have to down
        // cast it.
        const result = try self.buildConvert(scalar_result_ty, count);
        return try result.materialize(self);
    }

    fn airSelect(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const extra = self.air.extraData(Air.Bin, pl_op.payload).data;
        const pred = try self.temporary(pl_op.operand);
        const a = try self.temporary(extra.lhs);
        const b = try self.temporary(extra.rhs);

        const result = try self.buildSelect(pred, a, b);
        return try result.materialize(self);
    }

    fn airSplat(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;

        const operand_id = try self.resolve(ty_op.operand);
        const result_ty = self.typeOfIndex(inst);

        return try self.constructCompositeSplat(result_ty, operand_id);
    }

    fn airReduce(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const reduce = self.air.instructions.items(.data)[@intFromEnum(inst)].reduce;
        const operand = try self.resolve(reduce.operand);
        const operand_ty = self.typeOf(reduce.operand);
        const scalar_ty = operand_ty.scalarType(zcu);
        const scalar_ty_id = try self.resolveType(scalar_ty, .direct);
        const info = self.arithmeticTypeInfo(operand_ty);
        const len = operand_ty.vectorLen(zcu);
        const first = try self.extractVectorComponent(scalar_ty, operand, 0);

        switch (reduce.operation) {
            .Min, .Max => |op| {
                var result = Temporary.init(scalar_ty, first);
                const cmp_op: MinMax = switch (op) {
                    .Max => .max,
                    .Min => .min,
                    else => unreachable,
                };
                for (1..len) |i| {
                    const lhs = result;
                    const rhs_id = try self.extractVectorComponent(scalar_ty, operand, @intCast(i));
                    const rhs = Temporary.init(scalar_ty, rhs_id);

                    result = try self.minMax(lhs, rhs, cmp_op);
                }

                return try result.materialize(self);
            },
            else => {},
        }

        var result_id = first;

        const opcode: Opcode = switch (info.class) {
            .bool => switch (reduce.operation) {
                .And => .OpLogicalAnd,
                .Or => .OpLogicalOr,
                .Xor => .OpLogicalNotEqual,
                else => unreachable,
            },
            .strange_integer, .integer => switch (reduce.operation) {
                .And => .OpBitwiseAnd,
                .Or => .OpBitwiseOr,
                .Xor => .OpBitwiseXor,
                .Add => .OpIAdd,
                .Mul => .OpIMul,
                else => unreachable,
            },
            .float => switch (reduce.operation) {
                .Add => .OpFAdd,
                .Mul => .OpFMul,
                else => unreachable,
            },
            .composite_integer => unreachable, // TODO
        };

        for (1..len) |i| {
            const lhs = result_id;
            const rhs = try self.extractVectorComponent(scalar_ty, operand, @intCast(i));
            result_id = self.spv.allocId();

            try self.func.body.emitRaw(self.spv.gpa, opcode, 4);
            self.func.body.writeOperand(spec.Id, scalar_ty_id);
            self.func.body.writeOperand(spec.Id, result_id);
            self.func.body.writeOperand(spec.Id, lhs);
            self.func.body.writeOperand(spec.Id, rhs);
        }

        return result_id;
    }

    fn airShuffleOne(ng: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = ng.pt;
        const zcu = pt.zcu;
        const gpa = zcu.gpa;

        const unwrapped = ng.air.unwrapShuffleOne(zcu, inst);
        const mask = unwrapped.mask;
        const result_ty = unwrapped.result_ty;
        const elem_ty = result_ty.childType(zcu);
        const operand = try ng.resolve(unwrapped.operand);

        const constituents = try gpa.alloc(Id, mask.len);
        defer gpa.free(constituents);

        for (constituents, mask) |*id, mask_elem| {
            id.* = switch (mask_elem.unwrap()) {
                .elem => |idx| try ng.extractVectorComponent(elem_ty, operand, idx),
                .value => |val| try ng.constant(elem_ty, .fromInterned(val), .direct),
            };
        }

        const result_ty_id = try ng.resolveType(result_ty, .direct);
        return try ng.constructComposite(result_ty_id, constituents);
    }

    fn airShuffleTwo(ng: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = ng.pt;
        const zcu = pt.zcu;
        const gpa = zcu.gpa;

        const unwrapped = ng.air.unwrapShuffleTwo(zcu, inst);
        const mask = unwrapped.mask;
        const result_ty = unwrapped.result_ty;
        const elem_ty = result_ty.childType(zcu);
        const elem_ty_id = try ng.resolveType(elem_ty, .direct);
        const operand_a = try ng.resolve(unwrapped.operand_a);
        const operand_b = try ng.resolve(unwrapped.operand_b);

        const constituents = try gpa.alloc(Id, mask.len);
        defer gpa.free(constituents);

        for (constituents, mask) |*id, mask_elem| {
            id.* = switch (mask_elem.unwrap()) {
                .a_elem => |idx| try ng.extractVectorComponent(elem_ty, operand_a, idx),
                .b_elem => |idx| try ng.extractVectorComponent(elem_ty, operand_b, idx),
                .undef => try ng.spv.constUndef(elem_ty_id),
            };
        }

        const result_ty_id = try ng.resolveType(result_ty, .direct);
        return try ng.constructComposite(result_ty_id, constituents);
    }

    fn indicesToIds(self: *NavGen, indices: []const u32) ![]Id {
        const ids = try self.gpa.alloc(Id, indices.len);
        errdefer self.gpa.free(ids);
        for (indices, ids) |index, *id| {
            id.* = try self.constInt(Type.u32, index);
        }

        return ids;
    }

    fn accessChainId(
        self: *NavGen,
        result_ty_id: Id,
        base: Id,
        indices: []const Id,
    ) !Id {
        const result_id = self.spv.allocId();
        try self.func.body.emit(self.spv.gpa, .OpInBoundsAccessChain, .{
            .id_result_type = result_ty_id,
            .id_result = result_id,
            .base = base,
            .indexes = indices,
        });
        return result_id;
    }

    /// AccessChain is essentially PtrAccessChain with 0 as initial argument. The effective
    /// difference lies in whether the resulting type of the first dereference will be the
    /// same as that of the base pointer, or that of a dereferenced base pointer. AccessChain
    /// is the latter and PtrAccessChain is the former.
    fn accessChain(
        self: *NavGen,
        result_ty_id: Id,
        base: Id,
        indices: []const u32,
    ) !Id {
        const ids = try self.indicesToIds(indices);
        defer self.gpa.free(ids);
        return try self.accessChainId(result_ty_id, base, ids);
    }

    fn ptrAccessChain(
        self: *NavGen,
        result_ty_id: Id,
        base: Id,
        element: Id,
        indices: []const u32,
    ) !Id {
        const ids = try self.indicesToIds(indices);
        defer self.gpa.free(ids);

        const result_id = self.spv.allocId();
        switch (self.spv.target.os.tag) {
            .opencl, .amdhsa => {
                try self.func.body.emit(self.spv.gpa, .OpInBoundsPtrAccessChain, .{
                    .id_result_type = result_ty_id,
                    .id_result = result_id,
                    .base = base,
                    .element = element,
                    .indexes = ids,
                });
            },
            else => {
                try self.func.body.emit(self.spv.gpa, .OpPtrAccessChain, .{
                    .id_result_type = result_ty_id,
                    .id_result = result_id,
                    .base = base,
                    .element = element,
                    .indexes = ids,
                });
            },
        }
        return result_id;
    }

    fn ptrAdd(self: *NavGen, result_ty: Type, ptr_ty: Type, ptr_id: Id, offset_id: Id) !Id {
        const zcu = self.pt.zcu;
        const result_ty_id = try self.resolveType(result_ty, .direct);

        switch (ptr_ty.ptrSize(zcu)) {
            .one => {
                // Pointer to array
                // TODO: Is this correct?
                return try self.accessChainId(result_ty_id, ptr_id, &.{offset_id});
            },
            .c, .many => {
                return try self.ptrAccessChain(result_ty_id, ptr_id, offset_id, &.{});
            },
            .slice => {
                // TODO: This is probably incorrect. A slice should be returned here, though this is what llvm does.
                const slice_ptr_id = try self.extractField(result_ty, ptr_id, 0);
                return try self.ptrAccessChain(result_ty_id, slice_ptr_id, offset_id, &.{});
            },
        }
    }

    fn airPtrAdd(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr_id = try self.resolve(bin_op.lhs);
        const offset_id = try self.resolve(bin_op.rhs);
        const ptr_ty = self.typeOf(bin_op.lhs);
        const result_ty = self.typeOfIndex(inst);

        return try self.ptrAdd(result_ty, ptr_ty, ptr_id, offset_id);
    }

    fn airPtrSub(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr_id = try self.resolve(bin_op.lhs);
        const ptr_ty = self.typeOf(bin_op.lhs);
        const offset_id = try self.resolve(bin_op.rhs);
        const offset_ty = self.typeOf(bin_op.rhs);
        const offset_ty_id = try self.resolveType(offset_ty, .direct);
        const result_ty = self.typeOfIndex(inst);

        const negative_offset_id = self.spv.allocId();
        try self.func.body.emit(self.spv.gpa, .OpSNegate, .{
            .id_result_type = offset_ty_id,
            .id_result = negative_offset_id,
            .operand = offset_id,
        });
        return try self.ptrAdd(result_ty, ptr_ty, ptr_id, negative_offset_id);
    }

    fn cmp(
        self: *NavGen,
        op: std.math.CompareOperator,
        lhs: Temporary,
        rhs: Temporary,
    ) !Temporary {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const scalar_ty = lhs.ty.scalarType(zcu);
        const is_vector = lhs.ty.isVector(zcu);

        switch (scalar_ty.zigTypeTag(zcu)) {
            .int, .bool, .float => {},
            .@"enum" => {
                assert(!is_vector);
                const ty = lhs.ty.intTagType(zcu);
                return try self.cmp(op, lhs.pun(ty), rhs.pun(ty));
            },
            .@"struct" => {
                const struct_ty = zcu.typeToPackedStruct(scalar_ty).?;
                const ty = Type.fromInterned(struct_ty.backingIntTypeUnordered(ip));
                return try self.cmp(op, lhs.pun(ty), rhs.pun(ty));
            },
            .error_set => {
                assert(!is_vector);
                const err_int_ty = try pt.errorIntType();
                return try self.cmp(op, lhs.pun(err_int_ty), rhs.pun(err_int_ty));
            },
            .pointer => {
                assert(!is_vector);
                // Note that while SPIR-V offers OpPtrEqual and OpPtrNotEqual, they are
                // currently not implemented in the SPIR-V LLVM translator. Thus, we emit these using
                // OpConvertPtrToU...

                const usize_ty_id = try self.resolveType(Type.usize, .direct);

                const lhs_int_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpConvertPtrToU, .{
                    .id_result_type = usize_ty_id,
                    .id_result = lhs_int_id,
                    .pointer = try lhs.materialize(self),
                });

                const rhs_int_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpConvertPtrToU, .{
                    .id_result_type = usize_ty_id,
                    .id_result = rhs_int_id,
                    .pointer = try rhs.materialize(self),
                });

                const lhs_int = Temporary.init(Type.usize, lhs_int_id);
                const rhs_int = Temporary.init(Type.usize, rhs_int_id);
                return try self.cmp(op, lhs_int, rhs_int);
            },
            .optional => {
                assert(!is_vector);

                const ty = lhs.ty;

                const payload_ty = ty.optionalChild(zcu);
                if (ty.optionalReprIsPayload(zcu)) {
                    assert(payload_ty.hasRuntimeBitsIgnoreComptime(zcu));
                    assert(!payload_ty.isSlice(zcu));

                    return try self.cmp(op, lhs.pun(payload_ty), rhs.pun(payload_ty));
                }

                const lhs_id = try lhs.materialize(self);
                const rhs_id = try rhs.materialize(self);

                const lhs_valid_id = if (payload_ty.hasRuntimeBitsIgnoreComptime(zcu))
                    try self.extractField(Type.bool, lhs_id, 1)
                else
                    try self.convertToDirect(Type.bool, lhs_id);

                const rhs_valid_id = if (payload_ty.hasRuntimeBitsIgnoreComptime(zcu))
                    try self.extractField(Type.bool, rhs_id, 1)
                else
                    try self.convertToDirect(Type.bool, rhs_id);

                const lhs_valid = Temporary.init(Type.bool, lhs_valid_id);
                const rhs_valid = Temporary.init(Type.bool, rhs_valid_id);

                if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                    return try self.cmp(op, lhs_valid, rhs_valid);
                }

                // a = lhs_valid
                // b = rhs_valid
                // c = lhs_pl == rhs_pl
                //
                // For op == .eq we have:
                //   a == b && a -> c
                // = a == b && (!a || c)
                //
                // For op == .neq we have
                //   a == b && a -> c
                // = !(a == b && a -> c)
                // = a != b || !(a -> c
                // = a != b || !(!a || c)
                // = a != b || a && !c

                const lhs_pl_id = try self.extractField(payload_ty, lhs_id, 0);
                const rhs_pl_id = try self.extractField(payload_ty, rhs_id, 0);

                const lhs_pl = Temporary.init(payload_ty, lhs_pl_id);
                const rhs_pl = Temporary.init(payload_ty, rhs_pl_id);

                return switch (op) {
                    .eq => try self.buildBinary(
                        .l_and,
                        try self.cmp(.eq, lhs_valid, rhs_valid),
                        try self.buildBinary(
                            .l_or,
                            try self.buildUnary(.l_not, lhs_valid),
                            try self.cmp(.eq, lhs_pl, rhs_pl),
                        ),
                    ),
                    .neq => try self.buildBinary(
                        .l_or,
                        try self.cmp(.neq, lhs_valid, rhs_valid),
                        try self.buildBinary(
                            .l_and,
                            lhs_valid,
                            try self.cmp(.neq, lhs_pl, rhs_pl),
                        ),
                    ),
                    else => unreachable,
                };
            },
            else => |ty| return self.todo("implement cmp operation for '{s}' type", .{@tagName(ty)}),
        }

        const info = self.arithmeticTypeInfo(scalar_ty);
        const pred: CmpPredicate = switch (info.class) {
            .composite_integer => unreachable, // TODO
            .float => switch (op) {
                .eq => .f_oeq,
                .neq => .f_une,
                .lt => .f_olt,
                .lte => .f_ole,
                .gt => .f_ogt,
                .gte => .f_oge,
            },
            .bool => switch (op) {
                .eq => .l_eq,
                .neq => .l_ne,
                else => unreachable,
            },
            .integer, .strange_integer => switch (info.signedness) {
                .signed => switch (op) {
                    .eq => .i_eq,
                    .neq => .i_ne,
                    .lt => .s_lt,
                    .lte => .s_le,
                    .gt => .s_gt,
                    .gte => .s_ge,
                },
                .unsigned => switch (op) {
                    .eq => .i_eq,
                    .neq => .i_ne,
                    .lt => .u_lt,
                    .lte => .u_le,
                    .gt => .u_gt,
                    .gte => .u_ge,
                },
            },
        };

        return try self.buildCmp(pred, lhs, rhs);
    }

    fn airCmp(
        self: *NavGen,
        inst: Air.Inst.Index,
        comptime op: std.math.CompareOperator,
    ) !?Id {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const lhs = try self.temporary(bin_op.lhs);
        const rhs = try self.temporary(bin_op.rhs);

        const result = try self.cmp(op, lhs, rhs);
        return try result.materialize(self);
    }

    fn airVectorCmp(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const vec_cmp = self.air.extraData(Air.VectorCmp, ty_pl.payload).data;
        const lhs = try self.temporary(vec_cmp.lhs);
        const rhs = try self.temporary(vec_cmp.rhs);
        const op = vec_cmp.compareOperator();

        const result = try self.cmp(op, lhs, rhs);
        return try result.materialize(self);
    }

    /// Bitcast one type to another. Note: both types, input, output are expected in **direct** representation.
    fn bitCast(
        self: *NavGen,
        dst_ty: Type,
        src_ty: Type,
        src_id: Id,
    ) !Id {
        const zcu = self.pt.zcu;
        const src_ty_id = try self.resolveType(src_ty, .direct);
        const dst_ty_id = try self.resolveType(dst_ty, .direct);

        const result_id = blk: {
            if (src_ty_id == dst_ty_id) break :blk src_id;

            // TODO: Some more cases are missing here
            //   See fn bitCast in llvm.zig

            if (src_ty.zigTypeTag(zcu) == .int and dst_ty.isPtrAtRuntime(zcu)) {
                const result_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpConvertUToPtr, .{
                    .id_result_type = dst_ty_id,
                    .id_result = result_id,
                    .integer_value = src_id,
                });
                break :blk result_id;
            }

            // We can only use OpBitcast for specific conversions: between numerical types, and
            // between pointers. If the resolved spir-v types fall into this category then emit OpBitcast,
            // otherwise use a temporary and perform a pointer cast.
            const can_bitcast = (src_ty.isNumeric(zcu) and dst_ty.isNumeric(zcu)) or (src_ty.isPtrAtRuntime(zcu) and dst_ty.isPtrAtRuntime(zcu));
            if (can_bitcast) {
                const result_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                    .id_result_type = dst_ty_id,
                    .id_result = result_id,
                    .operand = src_id,
                });

                break :blk result_id;
            }

            const dst_ptr_ty_id = try self.ptrType(dst_ty, .function, .indirect);

            const tmp_id = try self.alloc(src_ty, .{ .storage_class = .function });
            try self.store(src_ty, tmp_id, src_id, .{});
            const casted_ptr_id = self.spv.allocId();
            try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                .id_result_type = dst_ptr_ty_id,
                .id_result = casted_ptr_id,
                .operand = tmp_id,
            });
            break :blk try self.load(dst_ty, casted_ptr_id, .{});
        };

        // Because strange integers use sign-extended representation, we may need to normalize
        // the result here.
        // TODO: This detail could cause stuff like @as(*const i1, @ptrCast(&@as(u1, 1))) to break
        // should we change the representation of strange integers?
        if (dst_ty.zigTypeTag(zcu) == .int) {
            const info = self.arithmeticTypeInfo(dst_ty);
            const result = try self.normalize(Temporary.init(dst_ty, result_id), info);
            return try result.materialize(self);
        }

        return result_id;
    }

    fn airBitCast(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        const result_ty = self.typeOfIndex(inst);
        if (operand_ty.toIntern() == .bool_type) {
            const operand = try self.temporary(ty_op.operand);
            const result = try self.intFromBool(operand);
            return try result.materialize(self);
        }
        const operand_id = try self.resolve(ty_op.operand);
        return try self.bitCast(result_ty, operand_ty, operand_id);
    }

    fn airIntCast(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const src = try self.temporary(ty_op.operand);
        const dst_ty = self.typeOfIndex(inst);

        const src_info = self.arithmeticTypeInfo(src.ty);
        const dst_info = self.arithmeticTypeInfo(dst_ty);

        if (src_info.backing_bits == dst_info.backing_bits) {
            return try src.materialize(self);
        }

        const converted = try self.buildConvert(dst_ty, src);

        // Make sure to normalize the result if shrinking.
        // Because strange ints are sign extended in their backing
        // type, we don't need to normalize when growing the type. The
        // representation is already the same.
        const result = if (dst_info.bits < src_info.bits)
            try self.normalize(converted, dst_info)
        else
            converted;

        return try result.materialize(self);
    }

    fn intFromPtr(self: *NavGen, operand_id: Id) !Id {
        const result_type_id = try self.resolveType(Type.usize, .direct);
        const result_id = self.spv.allocId();
        try self.func.body.emit(self.spv.gpa, .OpConvertPtrToU, .{
            .id_result_type = result_type_id,
            .id_result = result_id,
            .pointer = operand_id,
        });
        return result_id;
    }

    fn airFloatFromInt(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        const operand_id = try self.resolve(ty_op.operand);
        const result_ty = self.typeOfIndex(inst);
        return try self.floatFromInt(result_ty, operand_ty, operand_id);
    }

    fn floatFromInt(self: *NavGen, result_ty: Type, operand_ty: Type, operand_id: Id) !Id {
        const operand_info = self.arithmeticTypeInfo(operand_ty);
        const result_id = self.spv.allocId();
        const result_ty_id = try self.resolveType(result_ty, .direct);
        switch (operand_info.signedness) {
            .signed => try self.func.body.emit(self.spv.gpa, .OpConvertSToF, .{
                .id_result_type = result_ty_id,
                .id_result = result_id,
                .signed_value = operand_id,
            }),
            .unsigned => try self.func.body.emit(self.spv.gpa, .OpConvertUToF, .{
                .id_result_type = result_ty_id,
                .id_result = result_id,
                .unsigned_value = operand_id,
            }),
        }
        return result_id;
    }

    fn airIntFromFloat(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const result_ty = self.typeOfIndex(inst);
        return try self.intFromFloat(result_ty, operand_id);
    }

    fn intFromFloat(self: *NavGen, result_ty: Type, operand_id: Id) !Id {
        const result_info = self.arithmeticTypeInfo(result_ty);
        const result_ty_id = try self.resolveType(result_ty, .direct);
        const result_id = self.spv.allocId();
        switch (result_info.signedness) {
            .signed => try self.func.body.emit(self.spv.gpa, .OpConvertFToS, .{
                .id_result_type = result_ty_id,
                .id_result = result_id,
                .float_value = operand_id,
            }),
            .unsigned => try self.func.body.emit(self.spv.gpa, .OpConvertFToU, .{
                .id_result_type = result_ty_id,
                .id_result = result_id,
                .float_value = operand_id,
            }),
        }
        return result_id;
    }

    fn airFloatCast(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand = try self.temporary(ty_op.operand);
        const dest_ty = self.typeOfIndex(inst);
        const result = try self.buildConvert(dest_ty, operand);
        return try result.materialize(self);
    }

    fn airNot(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand = try self.temporary(ty_op.operand);
        const result_ty = self.typeOfIndex(inst);
        const info = self.arithmeticTypeInfo(result_ty);

        const result = switch (info.class) {
            .bool => try self.buildUnary(.l_not, operand),
            .float => unreachable,
            .composite_integer => unreachable, // TODO
            .strange_integer, .integer => blk: {
                const complement = try self.buildUnary(.bit_not, operand);
                break :blk try self.normalize(complement, info);
            },
        };

        return try result.materialize(self);
    }

    fn airArrayToSlice(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const array_ptr_ty = self.typeOf(ty_op.operand);
        const array_ty = array_ptr_ty.childType(zcu);
        const slice_ty = self.typeOfIndex(inst);
        const elem_ptr_ty = slice_ty.slicePtrFieldType(zcu);

        const elem_ptr_ty_id = try self.resolveType(elem_ptr_ty, .direct);

        const array_ptr_id = try self.resolve(ty_op.operand);
        const len_id = try self.constInt(Type.usize, array_ty.arrayLen(zcu));

        const elem_ptr_id = if (!array_ty.hasRuntimeBitsIgnoreComptime(zcu))
            // Note: The pointer is something like *opaque{}, so we need to bitcast it to the element type.
            try self.bitCast(elem_ptr_ty, array_ptr_ty, array_ptr_id)
        else
            // Convert the pointer-to-array to a pointer to the first element.
            try self.accessChain(elem_ptr_ty_id, array_ptr_id, &.{0});

        const slice_ty_id = try self.resolveType(slice_ty, .direct);
        return try self.constructComposite(slice_ty_id, &.{ elem_ptr_id, len_id });
    }

    fn airSlice(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr_id = try self.resolve(bin_op.lhs);
        const len_id = try self.resolve(bin_op.rhs);
        const slice_ty = self.typeOfIndex(inst);
        const slice_ty_id = try self.resolveType(slice_ty, .direct);
        return try self.constructComposite(slice_ty_id, &.{ ptr_id, len_id });
    }

    fn airAggregateInit(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const result_ty = self.typeOfIndex(inst);
        const len: usize = @intCast(result_ty.arrayLen(zcu));
        const elements: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[ty_pl.payload..][0..len]);

        switch (result_ty.zigTypeTag(zcu)) {
            .@"struct" => {
                if (zcu.typeToPackedStruct(result_ty)) |struct_type| {
                    comptime assert(Type.packed_struct_layout_version == 2);
                    const backing_int_ty = Type.fromInterned(struct_type.backingIntTypeUnordered(ip));
                    var running_int_id = try self.constInt(backing_int_ty, 0);
                    var running_bits: u16 = 0;
                    for (struct_type.field_types.get(ip), elements) |field_ty_ip, element| {
                        const field_ty = Type.fromInterned(field_ty_ip);
                        if (!field_ty.hasRuntimeBitsIgnoreComptime(zcu)) continue;
                        const field_id = try self.resolve(element);
                        const ty_bit_size: u16 = @intCast(field_ty.bitSize(zcu));
                        const field_int_ty = try self.pt.intType(.unsigned, ty_bit_size);
                        const field_int_id = blk: {
                            if (field_ty.isPtrAtRuntime(zcu)) {
                                assert(self.spv.target.cpu.arch == .spirv64 and
                                    field_ty.ptrAddressSpace(zcu) == .storage_buffer);
                                break :blk try self.intFromPtr(field_id);
                            }
                            break :blk try self.bitCast(field_int_ty, field_ty, field_id);
                        };
                        const shift_rhs = try self.constInt(backing_int_ty, running_bits);
                        const extended_int_conv = try self.buildConvert(backing_int_ty, .{
                            .ty = field_int_ty,
                            .value = .{ .singleton = field_int_id },
                        });
                        const shifted = try self.buildBinary(.sll, extended_int_conv, .{
                            .ty = backing_int_ty,
                            .value = .{ .singleton = shift_rhs },
                        });
                        const running_int_tmp = try self.buildBinary(
                            .bit_or,
                            .{ .ty = backing_int_ty, .value = .{ .singleton = running_int_id } },
                            shifted,
                        );
                        running_int_id = try running_int_tmp.materialize(self);
                        running_bits += ty_bit_size;
                    }
                    return running_int_id;
                }

                const types = try self.gpa.alloc(Type, elements.len);
                defer self.gpa.free(types);
                const constituents = try self.gpa.alloc(Id, elements.len);
                defer self.gpa.free(constituents);
                var index: usize = 0;

                switch (ip.indexToKey(result_ty.toIntern())) {
                    .tuple_type => |tuple| {
                        for (tuple.types.get(ip), elements, 0..) |field_ty, element, i| {
                            if ((try result_ty.structFieldValueComptime(pt, i)) != null) continue;
                            assert(Type.fromInterned(field_ty).hasRuntimeBits(zcu));

                            const id = try self.resolve(element);
                            types[index] = Type.fromInterned(field_ty);
                            constituents[index] = try self.convertToIndirect(Type.fromInterned(field_ty), id);
                            index += 1;
                        }
                    },
                    .struct_type => {
                        const struct_type = ip.loadStructType(result_ty.toIntern());
                        var it = struct_type.iterateRuntimeOrder(ip);
                        for (elements, 0..) |element, i| {
                            const field_index = it.next().?;
                            if ((try result_ty.structFieldValueComptime(pt, i)) != null) continue;
                            const field_ty = Type.fromInterned(struct_type.field_types.get(ip)[field_index]);
                            assert(field_ty.hasRuntimeBitsIgnoreComptime(zcu));

                            const id = try self.resolve(element);
                            types[index] = field_ty;
                            constituents[index] = try self.convertToIndirect(field_ty, id);
                            index += 1;
                        }
                    },
                    else => unreachable,
                }

                const result_ty_id = try self.resolveType(result_ty, .direct);
                return try self.constructComposite(result_ty_id, constituents[0..index]);
            },
            .vector => {
                const n_elems = result_ty.vectorLen(zcu);
                const elem_ids = try self.gpa.alloc(Id, n_elems);
                defer self.gpa.free(elem_ids);

                for (elements, 0..) |element, i| {
                    elem_ids[i] = try self.resolve(element);
                }

                const result_ty_id = try self.resolveType(result_ty, .direct);
                return try self.constructComposite(result_ty_id, elem_ids);
            },
            .array => {
                const array_info = result_ty.arrayInfo(zcu);
                const n_elems: usize = @intCast(result_ty.arrayLenIncludingSentinel(zcu));
                const elem_ids = try self.gpa.alloc(Id, n_elems);
                defer self.gpa.free(elem_ids);

                for (elements, 0..) |element, i| {
                    const id = try self.resolve(element);
                    elem_ids[i] = try self.convertToIndirect(array_info.elem_type, id);
                }

                if (array_info.sentinel) |sentinel_val| {
                    elem_ids[n_elems - 1] = try self.constant(array_info.elem_type, sentinel_val, .indirect);
                }

                const result_ty_id = try self.resolveType(result_ty, .direct);
                return try self.constructComposite(result_ty_id, elem_ids);
            },
            else => unreachable,
        }
    }

    fn sliceOrArrayLen(self: *NavGen, operand_id: Id, ty: Type) !Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        switch (ty.ptrSize(zcu)) {
            .slice => return self.extractField(Type.usize, operand_id, 1),
            .one => {
                const array_ty = ty.childType(zcu);
                const elem_ty = array_ty.childType(zcu);
                const abi_size = elem_ty.abiSize(zcu);
                const size = array_ty.arrayLenIncludingSentinel(zcu) * abi_size;
                return try self.constInt(Type.usize, size);
            },
            .many, .c => unreachable,
        }
    }

    fn sliceOrArrayPtr(self: *NavGen, operand_id: Id, ty: Type) !Id {
        const zcu = self.pt.zcu;
        if (ty.isSlice(zcu)) {
            const ptr_ty = ty.slicePtrFieldType(zcu);
            return self.extractField(ptr_ty, operand_id, 0);
        }
        return operand_id;
    }

    fn airMemcpy(self: *NavGen, inst: Air.Inst.Index) !void {
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const dest_slice = try self.resolve(bin_op.lhs);
        const src_slice = try self.resolve(bin_op.rhs);
        const dest_ty = self.typeOf(bin_op.lhs);
        const src_ty = self.typeOf(bin_op.rhs);
        const dest_ptr = try self.sliceOrArrayPtr(dest_slice, dest_ty);
        const src_ptr = try self.sliceOrArrayPtr(src_slice, src_ty);
        const len = try self.sliceOrArrayLen(dest_slice, dest_ty);
        try self.func.body.emit(self.spv.gpa, .OpCopyMemorySized, .{
            .target = dest_ptr,
            .source = src_ptr,
            .size = len,
        });
    }

    fn airMemmove(self: *NavGen, inst: Air.Inst.Index) !void {
        _ = inst;
        return self.fail("TODO implement airMemcpy for spirv", .{});
    }

    fn airSliceField(self: *NavGen, inst: Air.Inst.Index, field: u32) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const field_ty = self.typeOfIndex(inst);
        const operand_id = try self.resolve(ty_op.operand);
        return try self.extractField(field_ty, operand_id, field);
    }

    fn airSliceElemPtr(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const slice_ty = self.typeOf(bin_op.lhs);
        if (!slice_ty.isVolatilePtr(zcu) and self.liveness.isUnused(inst)) return null;

        const slice_id = try self.resolve(bin_op.lhs);
        const index_id = try self.resolve(bin_op.rhs);

        const ptr_ty = self.typeOfIndex(inst);
        const ptr_ty_id = try self.resolveType(ptr_ty, .direct);

        const slice_ptr = try self.extractField(ptr_ty, slice_id, 0);
        return try self.ptrAccessChain(ptr_ty_id, slice_ptr, index_id, &.{});
    }

    fn airSliceElemVal(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const slice_ty = self.typeOf(bin_op.lhs);
        if (!slice_ty.isVolatilePtr(zcu) and self.liveness.isUnused(inst)) return null;

        const slice_id = try self.resolve(bin_op.lhs);
        const index_id = try self.resolve(bin_op.rhs);

        const ptr_ty = slice_ty.slicePtrFieldType(zcu);
        const ptr_ty_id = try self.resolveType(ptr_ty, .direct);

        const slice_ptr = try self.extractField(ptr_ty, slice_id, 0);
        const elem_ptr = try self.ptrAccessChain(ptr_ty_id, slice_ptr, index_id, &.{});
        return try self.load(slice_ty.childType(zcu), elem_ptr, .{ .is_volatile = slice_ty.isVolatilePtr(zcu) });
    }

    fn ptrElemPtr(self: *NavGen, ptr_ty: Type, ptr_id: Id, index_id: Id) !Id {
        const zcu = self.pt.zcu;
        // Construct new pointer type for the resulting pointer
        const elem_ty = ptr_ty.elemType2(zcu); // use elemType() so that we get T for *[N]T.
        const elem_ptr_ty_id = try self.ptrType(elem_ty, self.spvStorageClass(ptr_ty.ptrAddressSpace(zcu)), .indirect);
        if (ptr_ty.isSinglePointer(zcu)) {
            // Pointer-to-array. In this case, the resulting pointer is not of the same type
            // as the ptr_ty (we want a *T, not a *[N]T), and hence we need to use accessChain.
            return try self.accessChainId(elem_ptr_ty_id, ptr_id, &.{index_id});
        } else {
            // Resulting pointer type is the same as the ptr_ty, so use ptrAccessChain
            return try self.ptrAccessChain(elem_ptr_ty_id, ptr_id, index_id, &.{});
        }
    }

    fn airPtrElemPtr(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const src_ptr_ty = self.typeOf(bin_op.lhs);
        const elem_ty = src_ptr_ty.childType(zcu);
        const ptr_id = try self.resolve(bin_op.lhs);

        if (!elem_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            const dst_ptr_ty = self.typeOfIndex(inst);
            return try self.bitCast(dst_ptr_ty, src_ptr_ty, ptr_id);
        }

        const index_id = try self.resolve(bin_op.rhs);
        return try self.ptrElemPtr(src_ptr_ty, ptr_id, index_id);
    }

    fn airArrayElemVal(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const array_ty = self.typeOf(bin_op.lhs);
        const elem_ty = array_ty.childType(zcu);
        const array_id = try self.resolve(bin_op.lhs);
        const index_id = try self.resolve(bin_op.rhs);

        // SPIR-V doesn't have an array indexing function for some damn reason.
        // For now, just generate a temporary and use that.
        // TODO: This backend probably also should use isByRef from llvm...

        const is_vector = array_ty.isVector(zcu);

        const elem_repr: Repr = if (is_vector) .direct else .indirect;
        const ptr_array_ty_id = try self.ptrType(array_ty, .function, .direct);
        const ptr_elem_ty_id = try self.ptrType(elem_ty, .function, elem_repr);

        const tmp_id = self.spv.allocId();
        try self.func.prologue.emit(self.spv.gpa, .OpVariable, .{
            .id_result_type = ptr_array_ty_id,
            .id_result = tmp_id,
            .storage_class = .function,
        });

        try self.func.body.emit(self.spv.gpa, .OpStore, .{
            .pointer = tmp_id,
            .object = array_id,
        });

        const elem_ptr_id = try self.accessChainId(ptr_elem_ty_id, tmp_id, &.{index_id});

        const result_id = self.spv.allocId();
        try self.func.body.emit(self.spv.gpa, .OpLoad, .{
            .id_result_type = try self.resolveType(elem_ty, elem_repr),
            .id_result = result_id,
            .pointer = elem_ptr_id,
        });

        if (is_vector) {
            // Result is already in direct representation
            return result_id;
        }

        // This is an array type; the elements are stored in indirect representation.
        // We have to convert the type to direct.

        return try self.convertToDirect(elem_ty, result_id);
    }

    fn airPtrElemVal(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const ptr_ty = self.typeOf(bin_op.lhs);
        const elem_ty = self.typeOfIndex(inst);
        const ptr_id = try self.resolve(bin_op.lhs);
        const index_id = try self.resolve(bin_op.rhs);
        const elem_ptr_id = try self.ptrElemPtr(ptr_ty, ptr_id, index_id);
        return try self.load(elem_ty, elem_ptr_id, .{ .is_volatile = ptr_ty.isVolatilePtr(zcu) });
    }

    fn airVectorStoreElem(self: *NavGen, inst: Air.Inst.Index) !void {
        const zcu = self.pt.zcu;
        const data = self.air.instructions.items(.data)[@intFromEnum(inst)].vector_store_elem;
        const extra = self.air.extraData(Air.Bin, data.payload).data;

        const vector_ptr_ty = self.typeOf(data.vector_ptr);
        const vector_ty = vector_ptr_ty.childType(zcu);
        const scalar_ty = vector_ty.scalarType(zcu);

        const storage_class = self.spvStorageClass(vector_ptr_ty.ptrAddressSpace(zcu));
        const scalar_ptr_ty_id = try self.ptrType(scalar_ty, storage_class, .indirect);

        const vector_ptr = try self.resolve(data.vector_ptr);
        const index = try self.resolve(extra.lhs);
        const operand = try self.resolve(extra.rhs);

        const elem_ptr_id = try self.accessChainId(scalar_ptr_ty_id, vector_ptr, &.{index});
        try self.store(scalar_ty, elem_ptr_id, operand, .{
            .is_volatile = vector_ptr_ty.isVolatilePtr(zcu),
        });
    }

    fn airSetUnionTag(self: *NavGen, inst: Air.Inst.Index) !void {
        const zcu = self.pt.zcu;
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const un_ptr_ty = self.typeOf(bin_op.lhs);
        const un_ty = un_ptr_ty.childType(zcu);
        const layout = self.unionLayout(un_ty);

        if (layout.tag_size == 0) return;

        const tag_ty = un_ty.unionTagTypeSafety(zcu).?;
        const tag_ptr_ty_id = try self.ptrType(tag_ty, self.spvStorageClass(un_ptr_ty.ptrAddressSpace(zcu)), .indirect);

        const union_ptr_id = try self.resolve(bin_op.lhs);
        const new_tag_id = try self.resolve(bin_op.rhs);

        if (!layout.has_payload) {
            try self.store(tag_ty, union_ptr_id, new_tag_id, .{ .is_volatile = un_ptr_ty.isVolatilePtr(zcu) });
        } else {
            const ptr_id = try self.accessChain(tag_ptr_ty_id, union_ptr_id, &.{layout.tag_index});
            try self.store(tag_ty, ptr_id, new_tag_id, .{ .is_volatile = un_ptr_ty.isVolatilePtr(zcu) });
        }
    }

    fn airGetUnionTag(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const un_ty = self.typeOf(ty_op.operand);

        const zcu = self.pt.zcu;
        const layout = self.unionLayout(un_ty);
        if (layout.tag_size == 0) return null;

        const union_handle = try self.resolve(ty_op.operand);
        if (!layout.has_payload) return union_handle;

        const tag_ty = un_ty.unionTagTypeSafety(zcu).?;
        return try self.extractField(tag_ty, union_handle, layout.tag_index);
    }

    fn unionInit(
        self: *NavGen,
        ty: Type,
        active_field: u32,
        payload: ?Id,
    ) !Id {
        // To initialize a union, generate a temporary variable with the
        // union type, then get the field pointer and pointer-cast it to the
        // right type to store it. Finally load the entire union.

        // Note: The result here is not cached, because it generates runtime code.

        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const union_ty = zcu.typeToUnion(ty).?;
        const tag_ty = Type.fromInterned(union_ty.enum_tag_ty);

        const layout = self.unionLayout(ty);
        const payload_ty = Type.fromInterned(union_ty.field_types.get(ip)[active_field]);

        if (union_ty.flagsUnordered(ip).layout == .@"packed") {
            if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                const int_ty = try pt.intType(.unsigned, @intCast(ty.bitSize(zcu)));
                return self.constInt(int_ty, 0);
            }

            assert(payload != null);
            if (payload_ty.isInt(zcu)) {
                if (ty.bitSize(zcu) == payload_ty.bitSize(zcu)) {
                    return self.bitCast(ty, payload_ty, payload.?);
                }

                const trunc = try self.buildConvert(ty, .{ .ty = payload_ty, .value = .{ .singleton = payload.? } });
                return try trunc.materialize(self);
            }

            const payload_int_ty = try pt.intType(.unsigned, @intCast(payload_ty.bitSize(zcu)));
            const payload_int = if (payload_ty.ip_index == .bool_type)
                try self.convertToIndirect(payload_ty, payload.?)
            else
                try self.bitCast(payload_int_ty, payload_ty, payload.?);
            const trunc = try self.buildConvert(ty, .{ .ty = payload_int_ty, .value = .{ .singleton = payload_int } });
            return try trunc.materialize(self);
        }

        const tag_int = if (layout.tag_size != 0) blk: {
            const tag_val = try pt.enumValueFieldIndex(tag_ty, active_field);
            const tag_int_val = try tag_val.intFromEnum(tag_ty, pt);
            break :blk tag_int_val.toUnsignedInt(zcu);
        } else 0;

        if (!layout.has_payload) {
            return try self.constInt(tag_ty, tag_int);
        }

        const tmp_id = try self.alloc(ty, .{ .storage_class = .function });

        if (layout.tag_size != 0) {
            const tag_ptr_ty_id = try self.ptrType(tag_ty, .function, .indirect);
            const ptr_id = try self.accessChain(tag_ptr_ty_id, tmp_id, &.{@as(u32, @intCast(layout.tag_index))});
            const tag_id = try self.constInt(tag_ty, tag_int);
            try self.store(tag_ty, ptr_id, tag_id, .{});
        }

        if (payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            const pl_ptr_ty_id = try self.ptrType(layout.payload_ty, .function, .indirect);
            const pl_ptr_id = try self.accessChain(pl_ptr_ty_id, tmp_id, &.{layout.payload_index});
            const active_pl_ptr_id = if (!layout.payload_ty.eql(payload_ty, zcu)) blk: {
                const active_pl_ptr_ty_id = try self.ptrType(payload_ty, .function, .indirect);
                const active_pl_ptr_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                    .id_result_type = active_pl_ptr_ty_id,
                    .id_result = active_pl_ptr_id,
                    .operand = pl_ptr_id,
                });
                break :blk active_pl_ptr_id;
            } else pl_ptr_id;

            try self.store(payload_ty, active_pl_ptr_id, payload.?, .{});
        } else {
            assert(payload == null);
        }

        // Just leave the padding fields uninitialized...
        // TODO: Or should we initialize them with undef explicitly?

        return try self.load(ty, tmp_id, .{});
    }

    fn airUnionInit(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ip = &zcu.intern_pool;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const extra = self.air.extraData(Air.UnionInit, ty_pl.payload).data;
        const ty = self.typeOfIndex(inst);

        const union_obj = zcu.typeToUnion(ty).?;
        const field_ty = Type.fromInterned(union_obj.field_types.get(ip)[extra.field_index]);
        const payload = if (field_ty.hasRuntimeBitsIgnoreComptime(zcu))
            try self.resolve(extra.init)
        else
            null;
        return try self.unionInit(ty, extra.field_index, payload);
    }

    fn airStructFieldVal(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;

        const object_ty = self.typeOf(struct_field.struct_operand);
        const object_id = try self.resolve(struct_field.struct_operand);
        const field_index = struct_field.field_index;
        const field_ty = object_ty.fieldType(field_index, zcu);

        if (!field_ty.hasRuntimeBitsIgnoreComptime(zcu)) return null;

        switch (object_ty.zigTypeTag(zcu)) {
            .@"struct" => switch (object_ty.containerLayout(zcu)) {
                .@"packed" => {
                    const struct_ty = zcu.typeToPackedStruct(object_ty).?;
                    const bit_offset = zcu.structPackedFieldBitOffset(struct_ty, field_index);
                    const bit_offset_id = try self.constInt(.u16, bit_offset);
                    const signedness = if (field_ty.isInt(zcu)) field_ty.intInfo(zcu).signedness else .unsigned;
                    const field_bit_size: u16 = @intCast(field_ty.bitSize(zcu));
                    const field_int_ty = try pt.intType(signedness, field_bit_size);
                    const shift_lhs: Temporary = .{ .ty = object_ty, .value = .{ .singleton = object_id } };
                    const shift = try self.buildBinary(.srl, shift_lhs, .{ .ty = .u16, .value = .{ .singleton = bit_offset_id } });
                    const mask_id = try self.constInt(object_ty, (@as(u64, 1) << @as(u6, @intCast(field_bit_size))) - 1);
                    const masked = try self.buildBinary(.bit_and, shift, .{ .ty = object_ty, .value = .{ .singleton = mask_id } });
                    const result_id = blk: {
                        if (self.backingIntBits(field_bit_size).@"0" == self.backingIntBits(@intCast(object_ty.bitSize(zcu))).@"0")
                            break :blk try self.bitCast(field_int_ty, object_ty, try masked.materialize(self));
                        const trunc = try self.buildConvert(field_int_ty, masked);
                        break :blk try trunc.materialize(self);
                    };
                    if (field_ty.ip_index == .bool_type) return try self.convertToDirect(.bool, result_id);
                    if (field_ty.isInt(zcu)) return result_id;
                    return try self.bitCast(field_ty, field_int_ty, result_id);
                },
                else => return try self.extractField(field_ty, object_id, field_index),
            },
            .@"union" => switch (object_ty.containerLayout(zcu)) {
                .@"packed" => {
                    const backing_int_ty = try pt.intType(.unsigned, @intCast(object_ty.bitSize(zcu)));
                    const signedness = if (field_ty.isInt(zcu)) field_ty.intInfo(zcu).signedness else .unsigned;
                    const field_bit_size: u16 = @intCast(field_ty.bitSize(zcu));
                    const int_ty = try pt.intType(signedness, field_bit_size);
                    const mask_id = try self.constInt(backing_int_ty, (@as(u64, 1) << @as(u6, @intCast(field_bit_size))) - 1);
                    const masked = try self.buildBinary(
                        .bit_and,
                        .{ .ty = backing_int_ty, .value = .{ .singleton = object_id } },
                        .{ .ty = backing_int_ty, .value = .{ .singleton = mask_id } },
                    );
                    const result_id = blk: {
                        if (self.backingIntBits(field_bit_size).@"0" == self.backingIntBits(@intCast(backing_int_ty.bitSize(zcu))).@"0")
                            break :blk try self.bitCast(int_ty, backing_int_ty, try masked.materialize(self));
                        const trunc = try self.buildConvert(int_ty, masked);
                        break :blk try trunc.materialize(self);
                    };
                    if (field_ty.ip_index == .bool_type) return try self.convertToDirect(.bool, result_id);
                    if (field_ty.isInt(zcu)) return result_id;
                    return try self.bitCast(field_ty, int_ty, result_id);
                },
                else => {
                    // Store, ptr-elem-ptr, pointer-cast, load
                    const layout = self.unionLayout(object_ty);
                    assert(layout.has_payload);

                    const tmp_id = try self.alloc(object_ty, .{ .storage_class = .function });
                    try self.store(object_ty, tmp_id, object_id, .{});

                    const pl_ptr_ty_id = try self.ptrType(layout.payload_ty, .function, .indirect);
                    const pl_ptr_id = try self.accessChain(pl_ptr_ty_id, tmp_id, &.{layout.payload_index});

                    const active_pl_ptr_ty_id = try self.ptrType(field_ty, .function, .indirect);
                    const active_pl_ptr_id = self.spv.allocId();
                    try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                        .id_result_type = active_pl_ptr_ty_id,
                        .id_result = active_pl_ptr_id,
                        .operand = pl_ptr_id,
                    });
                    return try self.load(field_ty, active_pl_ptr_id, .{});
                },
            },
            else => unreachable,
        }
    }

    fn airFieldParentPtr(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const extra = self.air.extraData(Air.FieldParentPtr, ty_pl.payload).data;

        const parent_ty = ty_pl.ty.toType().childType(zcu);
        const result_ty_id = try self.resolveType(ty_pl.ty.toType(), .indirect);

        const field_ptr = try self.resolve(extra.field_ptr);
        const field_ptr_int = try self.intFromPtr(field_ptr);
        const field_offset = parent_ty.structFieldOffset(extra.field_index, zcu);

        const base_ptr_int = base_ptr_int: {
            if (field_offset == 0) break :base_ptr_int field_ptr_int;

            const field_offset_id = try self.constInt(Type.usize, field_offset);
            const field_ptr_tmp = Temporary.init(Type.usize, field_ptr_int);
            const field_offset_tmp = Temporary.init(Type.usize, field_offset_id);
            const result = try self.buildBinary(.i_sub, field_ptr_tmp, field_offset_tmp);
            break :base_ptr_int try result.materialize(self);
        };

        const base_ptr = self.spv.allocId();
        try self.func.body.emit(self.spv.gpa, .OpConvertUToPtr, .{
            .id_result_type = result_ty_id,
            .id_result = base_ptr,
            .integer_value = base_ptr_int,
        });

        return base_ptr;
    }

    fn structFieldPtr(
        self: *NavGen,
        result_ptr_ty: Type,
        object_ptr_ty: Type,
        object_ptr: Id,
        field_index: u32,
    ) !Id {
        const result_ty_id = try self.resolveType(result_ptr_ty, .direct);

        const zcu = self.pt.zcu;
        const object_ty = object_ptr_ty.childType(zcu);
        switch (object_ty.zigTypeTag(zcu)) {
            .pointer => {
                assert(object_ty.isSlice(zcu));
                return self.accessChain(result_ty_id, object_ptr, &.{field_index});
            },
            .@"struct" => switch (object_ty.containerLayout(zcu)) {
                .@"packed" => return self.todo("implement field access for packed structs", .{}),
                else => {
                    return try self.accessChain(result_ty_id, object_ptr, &.{field_index});
                },
            },
            .@"union" => {
                const layout = self.unionLayout(object_ty);
                if (!layout.has_payload) {
                    // Asked to get a pointer to a zero-sized field. Just lower this
                    // to undefined, there is no reason to make it be a valid pointer.
                    return try self.spv.constUndef(result_ty_id);
                }

                const storage_class = self.spvStorageClass(object_ptr_ty.ptrAddressSpace(zcu));
                const pl_ptr_ty_id = try self.ptrType(layout.payload_ty, storage_class, .indirect);
                const pl_ptr_id = blk: {
                    if (object_ty.containerLayout(zcu) == .@"packed") break :blk object_ptr;
                    break :blk try self.accessChain(pl_ptr_ty_id, object_ptr, &.{layout.payload_index});
                };

                const active_pl_ptr_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpBitcast, .{
                    .id_result_type = result_ty_id,
                    .id_result = active_pl_ptr_id,
                    .operand = pl_ptr_id,
                });
                return active_pl_ptr_id;
            },
            else => unreachable,
        }
    }

    fn airStructFieldPtrIndex(self: *NavGen, inst: Air.Inst.Index, field_index: u32) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const struct_ptr = try self.resolve(ty_op.operand);
        const struct_ptr_ty = self.typeOf(ty_op.operand);
        const result_ptr_ty = self.typeOfIndex(inst);
        return try self.structFieldPtr(result_ptr_ty, struct_ptr_ty, struct_ptr, field_index);
    }

    const AllocOptions = struct {
        initializer: ?Id = null,
        /// The final storage class of the pointer. This may be either `.Generic` or `.Function`.
        /// In either case, the local is allocated in the `.Function` storage class, and optionally
        /// cast back to `.Generic`.
        storage_class: StorageClass,
    };

    // Allocate a function-local variable, with possible initializer.
    // This function returns a pointer to a variable of type `ty`,
    // which is in the Generic address space. The variable is actually
    // placed in the Function address space.
    fn alloc(
        self: *NavGen,
        ty: Type,
        options: AllocOptions,
    ) !Id {
        const ptr_fn_ty_id = try self.ptrType(ty, .function, .indirect);

        // SPIR-V requires that OpVariable declarations for locals go into the first block, so we are just going to
        // directly generate them into func.prologue instead of the body.
        const var_id = self.spv.allocId();
        try self.func.prologue.emit(self.spv.gpa, .OpVariable, .{
            .id_result_type = ptr_fn_ty_id,
            .id_result = var_id,
            .storage_class = .function,
            .initializer = options.initializer,
        });

        switch (self.spv.target.os.tag) {
            .vulkan, .opengl => return var_id,
            else => {},
        }

        switch (options.storage_class) {
            .generic => {
                const ptr_gn_ty_id = try self.ptrType(ty, .generic, .indirect);
                // Convert to a generic pointer
                return self.castToGeneric(ptr_gn_ty_id, var_id);
            },
            .function => return var_id,
            else => unreachable,
        }
    }

    fn airAlloc(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const ptr_ty = self.typeOfIndex(inst);
        const child_ty = ptr_ty.childType(zcu);
        return try self.alloc(child_ty, .{
            .storage_class = self.spvStorageClass(ptr_ty.ptrAddressSpace(zcu)),
        });
    }

    fn airArg(self: *NavGen) Id {
        defer self.next_arg_index += 1;
        return self.args.items[self.next_arg_index];
    }

    /// Given a slice of incoming block connections, returns the block-id of the next
    /// block to jump to. This function emits instructions, so it should be emitted
    /// inside the merge block of the block.
    /// This function should only be called with structured control flow generation.
    fn structuredNextBlock(self: *NavGen, incoming: []const ControlFlow.Structured.Block.Incoming) !Id {
        assert(self.control_flow == .structured);

        const result_id = self.spv.allocId();
        const block_id_ty_id = try self.resolveType(Type.u32, .direct);
        try self.func.body.emitRaw(self.spv.gpa, .OpPhi, @intCast(2 + incoming.len * 2)); // result type + result + variable/parent...
        self.func.body.writeOperand(spec.Id, block_id_ty_id);
        self.func.body.writeOperand(spec.Id, result_id);

        for (incoming) |incoming_block| {
            self.func.body.writeOperand(spec.PairIdRefIdRef, .{ incoming_block.next_block, incoming_block.src_label });
        }

        return result_id;
    }

    /// Jumps to the block with the target block-id. This function must only be called when
    /// terminating a body, there should be no instructions after it.
    /// This function should only be called with structured control flow generation.
    fn structuredBreak(self: *NavGen, target_block: Id) !void {
        assert(self.control_flow == .structured);

        const sblock = self.control_flow.structured.block_stack.getLast();
        const merge_block = switch (sblock.*) {
            .selection => |*merge| blk: {
                const merge_label = self.spv.allocId();
                try merge.merge_stack.append(self.gpa, .{
                    .incoming = .{
                        .src_label = self.current_block_label,
                        .next_block = target_block,
                    },
                    .merge_block = merge_label,
                });
                break :blk merge_label;
            },
            // Loop blocks do not end in a break. Not through a direct break,
            // and also not through another instruction like cond_br or unreachable (these
            // situations are replaced by `cond_br` in sema, or there is a `block` instruction
            // placed around them).
            .loop => unreachable,
        };

        try self.func.body.emitBranch(self.spv.gpa, merge_block);
    }

    /// Generate a body in a way that exits the body using only structured constructs.
    /// Returns the block-id of the next block to jump to. After this function, a jump
    /// should still be emitted to the block that should follow this structured body.
    /// This function should only be called with structured control flow generation.
    fn genStructuredBody(
        self: *NavGen,
        /// This parameter defines the method that this structured body is exited with.
        block_merge_type: union(enum) {
            /// Using selection; early exits from this body are surrounded with
            /// if() statements.
            selection,
            /// Using loops; loops can be early exited by jumping to the merge block at
            /// any time.
            loop: struct {
                merge_label: Id,
                continue_label: Id,
            },
        },
        body: []const Air.Inst.Index,
    ) !Id {
        assert(self.control_flow == .structured);

        var sblock: ControlFlow.Structured.Block = switch (block_merge_type) {
            .loop => |merge| .{ .loop = .{
                .merge_block = merge.merge_label,
            } },
            .selection => .{ .selection = .{} },
        };
        defer sblock.deinit(self.gpa);

        {
            try self.control_flow.structured.block_stack.append(self.gpa, &sblock);
            defer _ = self.control_flow.structured.block_stack.pop();

            try self.genBody(body);
        }

        switch (sblock) {
            .selection => |merge| {
                // Now generate the merge block for all merges that
                // still need to be performed.
                const merge_stack = merge.merge_stack.items;

                // If no merges on the stack, this block didn't generate any jumps (all paths
                // ended with a return or an unreachable). In that case, we don't need to do
                // any merging.
                if (merge_stack.len == 0) {
                    // We still need to return a value of a next block to jump to.
                    // For example, if we have code like
                    //  if (x) {
                    //    if (y) return else return;
                    //  } else {}
                    // then we still need the outer to have an OpSelectionMerge and consequently
                    // a phi node. In that case we can just return bogus, since we know that its
                    // path will never be taken.

                    // Make sure that we are still in a block when exiting the function.
                    // TODO: Can we get rid of that?
                    try self.beginSpvBlock(self.spv.allocId());
                    const block_id_ty_id = try self.resolveType(Type.u32, .direct);
                    return try self.spv.constUndef(block_id_ty_id);
                }

                // The top-most merge actually only has a single source, the
                // final jump of the block, or the merge block of a sub-block, cond_br,
                // or loop. Therefore we just need to generate a block with a jump to the
                // next merge block.
                try self.beginSpvBlock(merge_stack[merge_stack.len - 1].merge_block);

                // Now generate a merge ladder for the remaining merges in the stack.
                var incoming = ControlFlow.Structured.Block.Incoming{
                    .src_label = self.current_block_label,
                    .next_block = merge_stack[merge_stack.len - 1].incoming.next_block,
                };
                var i = merge_stack.len - 1;
                while (i > 0) {
                    i -= 1;
                    const step = merge_stack[i];
                    try self.func.body.emitBranch(self.spv.gpa, step.merge_block);
                    try self.beginSpvBlock(step.merge_block);
                    const next_block = try self.structuredNextBlock(&.{ incoming, step.incoming });
                    incoming = .{
                        .src_label = step.merge_block,
                        .next_block = next_block,
                    };
                }

                return incoming.next_block;
            },
            .loop => |merge| {
                // Close the loop by jumping to the continue label
                try self.func.body.emitBranch(self.spv.gpa, block_merge_type.loop.continue_label);
                // For blocks we must simple merge all the incoming blocks to get the next block.
                try self.beginSpvBlock(merge.merge_block);
                return try self.structuredNextBlock(merge.merges.items);
            },
        }
    }

    fn airBlock(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const inst_datas = self.air.instructions.items(.data);
        const extra = self.air.extraData(Air.Block, inst_datas[@intFromEnum(inst)].ty_pl.payload);
        return self.lowerBlock(inst, @ptrCast(self.air.extra.items[extra.end..][0..extra.data.body_len]));
    }

    fn lowerBlock(self: *NavGen, inst: Air.Inst.Index, body: []const Air.Inst.Index) !?Id {
        // In AIR, a block doesn't really define an entry point like a block, but
        // more like a scope that breaks can jump out of and "return" a value from.
        // This cannot be directly modelled in SPIR-V, so in a block instruction,
        // we're going to split up the current block by first generating the code
        // of the block, then a label, and then generate the rest of the current
        // ir.Block in a different SPIR-V block.

        const pt = self.pt;
        const zcu = pt.zcu;
        const ty = self.typeOfIndex(inst);
        const have_block_result = ty.isFnOrHasRuntimeBitsIgnoreComptime(zcu);

        const cf = switch (self.control_flow) {
            .structured => |*cf| cf,
            .unstructured => |*cf| {
                var block = ControlFlow.Unstructured.Block{};
                defer block.incoming_blocks.deinit(self.gpa);

                // 4 chosen as arbitrary initial capacity.
                try block.incoming_blocks.ensureUnusedCapacity(self.gpa, 4);

                try cf.blocks.putNoClobber(self.gpa, inst, &block);
                defer assert(cf.blocks.remove(inst));

                try self.genBody(body);

                // Only begin a new block if there were actually any breaks towards it.
                if (block.label) |label| {
                    try self.beginSpvBlock(label);
                }

                if (!have_block_result)
                    return null;

                assert(block.label != null);
                const result_id = self.spv.allocId();
                const result_type_id = try self.resolveType(ty, .direct);

                try self.func.body.emitRaw(
                    self.spv.gpa,
                    .OpPhi,
                    // result type + result + variable/parent...
                    2 + @as(u16, @intCast(block.incoming_blocks.items.len * 2)),
                );
                self.func.body.writeOperand(spec.Id, result_type_id);
                self.func.body.writeOperand(spec.Id, result_id);

                for (block.incoming_blocks.items) |incoming| {
                    self.func.body.writeOperand(
                        spec.PairIdRefIdRef,
                        .{ incoming.break_value_id, incoming.src_label },
                    );
                }

                return result_id;
            },
        };

        const maybe_block_result_var_id = if (have_block_result) blk: {
            const block_result_var_id = try self.alloc(ty, .{ .storage_class = .function });
            try cf.block_results.putNoClobber(self.gpa, inst, block_result_var_id);
            break :blk block_result_var_id;
        } else null;
        defer if (have_block_result) assert(cf.block_results.remove(inst));

        const next_block = try self.genStructuredBody(.selection, body);

        // When encountering a block instruction, we are always at least in the function's scope,
        // so there always has to be another entry.
        assert(cf.block_stack.items.len > 0);

        // Check if the target of the branch was this current block.
        const this_block = try self.constInt(Type.u32, @intFromEnum(inst));
        const jump_to_this_block_id = self.spv.allocId();
        const bool_ty_id = try self.resolveType(Type.bool, .direct);
        try self.func.body.emit(self.spv.gpa, .OpIEqual, .{
            .id_result_type = bool_ty_id,
            .id_result = jump_to_this_block_id,
            .operand_1 = next_block,
            .operand_2 = this_block,
        });

        const sblock = cf.block_stack.getLast();

        if (ty.isNoReturn(zcu)) {
            // If this block is noreturn, this instruction is the last of a block,
            // and we must simply jump to the block's merge unconditionally.
            try self.structuredBreak(next_block);
        } else {
            switch (sblock.*) {
                .selection => |*merge| {
                    // To jump out of a selection block, push a new entry onto its merge stack and
                    // generate a conditional branch to there and to the instructions following this block.
                    const merge_label = self.spv.allocId();
                    const then_label = self.spv.allocId();
                    try self.func.body.emit(self.spv.gpa, .OpSelectionMerge, .{
                        .merge_block = merge_label,
                        .selection_control = .{},
                    });
                    try self.func.body.emit(self.spv.gpa, .OpBranchConditional, .{
                        .condition = jump_to_this_block_id,
                        .true_label = then_label,
                        .false_label = merge_label,
                    });
                    try merge.merge_stack.append(self.gpa, .{
                        .incoming = .{
                            .src_label = self.current_block_label,
                            .next_block = next_block,
                        },
                        .merge_block = merge_label,
                    });

                    try self.beginSpvBlock(then_label);
                },
                .loop => |*merge| {
                    // To jump out of a loop block, generate a conditional that exits the block
                    // to the loop merge if the target ID is not the one of this block.
                    const continue_label = self.spv.allocId();
                    try self.func.body.emit(self.spv.gpa, .OpBranchConditional, .{
                        .condition = jump_to_this_block_id,
                        .true_label = continue_label,
                        .false_label = merge.merge_block,
                    });
                    try merge.merges.append(self.gpa, .{
                        .src_label = self.current_block_label,
                        .next_block = next_block,
                    });
                    try self.beginSpvBlock(continue_label);
                },
            }
        }

        if (maybe_block_result_var_id) |block_result_var_id| {
            return try self.load(ty, block_result_var_id, .{});
        }

        return null;
    }

    fn airBr(self: *NavGen, inst: Air.Inst.Index) !void {
        const zcu = self.pt.zcu;
        const br = self.air.instructions.items(.data)[@intFromEnum(inst)].br;
        const operand_ty = self.typeOf(br.operand);

        switch (self.control_flow) {
            .structured => |*cf| {
                if (operand_ty.isFnOrHasRuntimeBitsIgnoreComptime(zcu)) {
                    const operand_id = try self.resolve(br.operand);
                    const block_result_var_id = cf.block_results.get(br.block_inst).?;
                    try self.store(operand_ty, block_result_var_id, operand_id, .{});
                }

                const next_block = try self.constInt(Type.u32, @intFromEnum(br.block_inst));
                try self.structuredBreak(next_block);
            },
            .unstructured => |cf| {
                const block = cf.blocks.get(br.block_inst).?;
                if (operand_ty.isFnOrHasRuntimeBitsIgnoreComptime(zcu)) {
                    const operand_id = try self.resolve(br.operand);
                    // current_block_label should not be undefined here, lest there
                    // is a br or br_void in the function's body.
                    try block.incoming_blocks.append(self.gpa, .{
                        .src_label = self.current_block_label,
                        .break_value_id = operand_id,
                    });
                }

                if (block.label == null) {
                    block.label = self.spv.allocId();
                }

                try self.func.body.emitBranch(self.spv.gpa, block.label.?);
            },
        }
    }

    fn airCondBr(self: *NavGen, inst: Air.Inst.Index) !void {
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const cond_br = self.air.extraData(Air.CondBr, pl_op.payload);
        const then_body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[cond_br.end..][0..cond_br.data.then_body_len]);
        const else_body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[cond_br.end + then_body.len ..][0..cond_br.data.else_body_len]);
        const condition_id = try self.resolve(pl_op.operand);

        const then_label = self.spv.allocId();
        const else_label = self.spv.allocId();

        switch (self.control_flow) {
            .structured => {
                const merge_label = self.spv.allocId();

                try self.func.body.emit(self.spv.gpa, .OpSelectionMerge, .{
                    .merge_block = merge_label,
                    .selection_control = .{},
                });
                try self.func.body.emit(self.spv.gpa, .OpBranchConditional, .{
                    .condition = condition_id,
                    .true_label = then_label,
                    .false_label = else_label,
                });

                try self.beginSpvBlock(then_label);
                const then_next = try self.genStructuredBody(.selection, then_body);
                const then_incoming = ControlFlow.Structured.Block.Incoming{
                    .src_label = self.current_block_label,
                    .next_block = then_next,
                };
                try self.func.body.emitBranch(self.spv.gpa, merge_label);

                try self.beginSpvBlock(else_label);
                const else_next = try self.genStructuredBody(.selection, else_body);
                const else_incoming = ControlFlow.Structured.Block.Incoming{
                    .src_label = self.current_block_label,
                    .next_block = else_next,
                };
                try self.func.body.emitBranch(self.spv.gpa, merge_label);

                try self.beginSpvBlock(merge_label);
                const next_block = try self.structuredNextBlock(&.{ then_incoming, else_incoming });

                try self.structuredBreak(next_block);
            },
            .unstructured => {
                try self.func.body.emit(self.spv.gpa, .OpBranchConditional, .{
                    .condition = condition_id,
                    .true_label = then_label,
                    .false_label = else_label,
                });

                try self.beginSpvBlock(then_label);
                try self.genBody(then_body);
                try self.beginSpvBlock(else_label);
                try self.genBody(else_body);
            },
        }
    }

    fn airLoop(self: *NavGen, inst: Air.Inst.Index) !void {
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const loop = self.air.extraData(Air.Block, ty_pl.payload);
        const body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[loop.end..][0..loop.data.body_len]);

        const body_label = self.spv.allocId();

        switch (self.control_flow) {
            .structured => {
                const header_label = self.spv.allocId();
                const merge_label = self.spv.allocId();
                const continue_label = self.spv.allocId();

                // The back-edge must point to the loop header, so generate a separate block for the
                // loop header so that we don't accidentally include some instructions from there
                // in the loop.
                try self.func.body.emitBranch(self.spv.gpa, header_label);
                try self.beginSpvBlock(header_label);

                // Emit loop header and jump to loop body
                try self.func.body.emit(self.spv.gpa, .OpLoopMerge, .{
                    .merge_block = merge_label,
                    .continue_target = continue_label,
                    .loop_control = .{},
                });
                try self.func.body.emitBranch(self.spv.gpa, body_label);

                try self.beginSpvBlock(body_label);

                const next_block = try self.genStructuredBody(.{ .loop = .{
                    .merge_label = merge_label,
                    .continue_label = continue_label,
                } }, body);
                try self.structuredBreak(next_block);

                try self.beginSpvBlock(continue_label);
                try self.func.body.emitBranch(self.spv.gpa, header_label);
            },
            .unstructured => {
                try self.func.body.emitBranch(self.spv.gpa, body_label);
                try self.beginSpvBlock(body_label);
                try self.genBody(body);
                try self.func.body.emitBranch(self.spv.gpa, body_label);
            },
        }
    }

    fn airLoad(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const ptr_ty = self.typeOf(ty_op.operand);
        const elem_ty = self.typeOfIndex(inst);
        const operand = try self.resolve(ty_op.operand);
        if (!ptr_ty.isVolatilePtr(zcu) and self.liveness.isUnused(inst)) return null;

        return try self.load(elem_ty, operand, .{ .is_volatile = ptr_ty.isVolatilePtr(zcu) });
    }

    fn airStore(self: *NavGen, inst: Air.Inst.Index) !void {
        const zcu = self.pt.zcu;
        const bin_op = self.air.instructions.items(.data)[@intFromEnum(inst)].bin_op;
        const ptr_ty = self.typeOf(bin_op.lhs);
        const elem_ty = ptr_ty.childType(zcu);
        const ptr = try self.resolve(bin_op.lhs);
        const value = try self.resolve(bin_op.rhs);

        try self.store(elem_ty, ptr, value, .{ .is_volatile = ptr_ty.isVolatilePtr(zcu) });
    }

    fn airRet(self: *NavGen, inst: Air.Inst.Index) !void {
        const pt = self.pt;
        const zcu = pt.zcu;
        const operand = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
        const ret_ty = self.typeOf(operand);
        if (!ret_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            const fn_info = zcu.typeToFunc(zcu.navValue(self.owner_nav).typeOf(zcu)).?;
            if (Type.fromInterned(fn_info.return_type).isError(zcu)) {
                // Functions with an empty error set are emitted with an error code
                // return type and return zero so they can be function pointers coerced
                // to functions that return anyerror.
                const no_err_id = try self.constInt(Type.anyerror, 0);
                return try self.func.body.emit(self.spv.gpa, .OpReturnValue, .{ .value = no_err_id });
            } else {
                return try self.func.body.emit(self.spv.gpa, .OpReturn, {});
            }
        }

        const operand_id = try self.resolve(operand);
        try self.func.body.emit(self.spv.gpa, .OpReturnValue, .{ .value = operand_id });
    }

    fn airRetLoad(self: *NavGen, inst: Air.Inst.Index) !void {
        const pt = self.pt;
        const zcu = pt.zcu;
        const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
        const ptr_ty = self.typeOf(un_op);
        const ret_ty = ptr_ty.childType(zcu);

        if (!ret_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            const fn_info = zcu.typeToFunc(zcu.navValue(self.owner_nav).typeOf(zcu)).?;
            if (Type.fromInterned(fn_info.return_type).isError(zcu)) {
                // Functions with an empty error set are emitted with an error code
                // return type and return zero so they can be function pointers coerced
                // to functions that return anyerror.
                const no_err_id = try self.constInt(Type.anyerror, 0);
                return try self.func.body.emit(self.spv.gpa, .OpReturnValue, .{ .value = no_err_id });
            } else {
                return try self.func.body.emit(self.spv.gpa, .OpReturn, {});
            }
        }

        const ptr = try self.resolve(un_op);
        const value = try self.load(ret_ty, ptr, .{ .is_volatile = ptr_ty.isVolatilePtr(zcu) });
        try self.func.body.emit(self.spv.gpa, .OpReturnValue, .{
            .value = value,
        });
    }

    fn airTry(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const err_union_id = try self.resolve(pl_op.operand);
        const extra = self.air.extraData(Air.Try, pl_op.payload);
        const body: []const Air.Inst.Index = @ptrCast(self.air.extra.items[extra.end..][0..extra.data.body_len]);

        const err_union_ty = self.typeOf(pl_op.operand);
        const payload_ty = self.typeOfIndex(inst);

        const bool_ty_id = try self.resolveType(Type.bool, .direct);

        const eu_layout = self.errorUnionLayout(payload_ty);

        if (!err_union_ty.errorUnionSet(zcu).errorSetIsEmpty(zcu)) {
            const err_id = if (eu_layout.payload_has_bits)
                try self.extractField(Type.anyerror, err_union_id, eu_layout.errorFieldIndex())
            else
                err_union_id;

            const zero_id = try self.constInt(Type.anyerror, 0);
            const is_err_id = self.spv.allocId();
            try self.func.body.emit(self.spv.gpa, .OpINotEqual, .{
                .id_result_type = bool_ty_id,
                .id_result = is_err_id,
                .operand_1 = err_id,
                .operand_2 = zero_id,
            });

            // When there is an error, we must evaluate `body`. Otherwise we must continue
            // with the current body.
            // Just generate a new block here, then generate a new block inline for the remainder of the body.

            const err_block = self.spv.allocId();
            const ok_block = self.spv.allocId();

            switch (self.control_flow) {
                .structured => {
                    // According to AIR documentation, this block is guaranteed
                    // to not break and end in a return instruction. Thus,
                    // for structured control flow, we can just naively use
                    // the ok block as the merge block here.
                    try self.func.body.emit(self.spv.gpa, .OpSelectionMerge, .{
                        .merge_block = ok_block,
                        .selection_control = .{},
                    });
                },
                .unstructured => {},
            }

            try self.func.body.emit(self.spv.gpa, .OpBranchConditional, .{
                .condition = is_err_id,
                .true_label = err_block,
                .false_label = ok_block,
            });

            try self.beginSpvBlock(err_block);
            try self.genBody(body);

            try self.beginSpvBlock(ok_block);
        }

        if (!eu_layout.payload_has_bits) {
            return null;
        }

        // Now just extract the payload, if required.
        return try self.extractField(payload_ty, err_union_id, eu_layout.payloadFieldIndex());
    }

    fn airErrUnionErr(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const err_union_ty = self.typeOf(ty_op.operand);
        const err_ty_id = try self.resolveType(Type.anyerror, .direct);

        if (err_union_ty.errorUnionSet(zcu).errorSetIsEmpty(zcu)) {
            // No error possible, so just return undefined.
            return try self.spv.constUndef(err_ty_id);
        }

        const payload_ty = err_union_ty.errorUnionPayload(zcu);
        const eu_layout = self.errorUnionLayout(payload_ty);

        if (!eu_layout.payload_has_bits) {
            // If no payload, error union is represented by error set.
            return operand_id;
        }

        return try self.extractField(Type.anyerror, operand_id, eu_layout.errorFieldIndex());
    }

    fn airErrUnionPayload(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const payload_ty = self.typeOfIndex(inst);
        const eu_layout = self.errorUnionLayout(payload_ty);

        if (!eu_layout.payload_has_bits) {
            return null; // No error possible.
        }

        return try self.extractField(payload_ty, operand_id, eu_layout.payloadFieldIndex());
    }

    fn airWrapErrUnionErr(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const err_union_ty = self.typeOfIndex(inst);
        const payload_ty = err_union_ty.errorUnionPayload(zcu);
        const operand_id = try self.resolve(ty_op.operand);
        const eu_layout = self.errorUnionLayout(payload_ty);

        if (!eu_layout.payload_has_bits) {
            return operand_id;
        }

        const payload_ty_id = try self.resolveType(payload_ty, .indirect);

        var members: [2]Id = undefined;
        members[eu_layout.errorFieldIndex()] = operand_id;
        members[eu_layout.payloadFieldIndex()] = try self.spv.constUndef(payload_ty_id);

        var types: [2]Type = undefined;
        types[eu_layout.errorFieldIndex()] = Type.anyerror;
        types[eu_layout.payloadFieldIndex()] = payload_ty;

        const err_union_ty_id = try self.resolveType(err_union_ty, .direct);
        return try self.constructComposite(err_union_ty_id, &members);
    }

    fn airWrapErrUnionPayload(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const err_union_ty = self.typeOfIndex(inst);
        const operand_id = try self.resolve(ty_op.operand);
        const payload_ty = self.typeOf(ty_op.operand);
        const eu_layout = self.errorUnionLayout(payload_ty);

        if (!eu_layout.payload_has_bits) {
            return try self.constInt(Type.anyerror, 0);
        }

        var members: [2]Id = undefined;
        members[eu_layout.errorFieldIndex()] = try self.constInt(Type.anyerror, 0);
        members[eu_layout.payloadFieldIndex()] = try self.convertToIndirect(payload_ty, operand_id);

        var types: [2]Type = undefined;
        types[eu_layout.errorFieldIndex()] = Type.anyerror;
        types[eu_layout.payloadFieldIndex()] = payload_ty;

        const err_union_ty_id = try self.resolveType(err_union_ty, .direct);
        return try self.constructComposite(err_union_ty_id, &members);
    }

    fn airIsNull(self: *NavGen, inst: Air.Inst.Index, is_pointer: bool, pred: enum { is_null, is_non_null }) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
        const operand_id = try self.resolve(un_op);
        const operand_ty = self.typeOf(un_op);
        const optional_ty = if (is_pointer) operand_ty.childType(zcu) else operand_ty;
        const payload_ty = optional_ty.optionalChild(zcu);

        const bool_ty_id = try self.resolveType(Type.bool, .direct);

        if (optional_ty.optionalReprIsPayload(zcu)) {
            // Pointer payload represents nullability: pointer or slice.
            const loaded_id = if (is_pointer)
                try self.load(optional_ty, operand_id, .{})
            else
                operand_id;

            const ptr_ty = if (payload_ty.isSlice(zcu))
                payload_ty.slicePtrFieldType(zcu)
            else
                payload_ty;

            const ptr_id = if (payload_ty.isSlice(zcu))
                try self.extractField(ptr_ty, loaded_id, 0)
            else
                loaded_id;

            const ptr_ty_id = try self.resolveType(ptr_ty, .direct);
            const null_id = try self.spv.constNull(ptr_ty_id);
            const null_tmp = Temporary.init(ptr_ty, null_id);
            const ptr = Temporary.init(ptr_ty, ptr_id);

            const op: std.math.CompareOperator = switch (pred) {
                .is_null => .eq,
                .is_non_null => .neq,
            };
            const result = try self.cmp(op, ptr, null_tmp);
            return try result.materialize(self);
        }

        const is_non_null_id = blk: {
            if (is_pointer) {
                if (payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
                    const storage_class = self.spvStorageClass(operand_ty.ptrAddressSpace(zcu));
                    const bool_ptr_ty_id = try self.ptrType(Type.bool, storage_class, .indirect);
                    const tag_ptr_id = try self.accessChain(bool_ptr_ty_id, operand_id, &.{1});
                    break :blk try self.load(Type.bool, tag_ptr_id, .{});
                }

                break :blk try self.load(Type.bool, operand_id, .{});
            }

            break :blk if (payload_ty.hasRuntimeBitsIgnoreComptime(zcu))
                try self.extractField(Type.bool, operand_id, 1)
            else
                // Optional representation is bool indicating whether the optional is set
                // Optionals with no payload are represented as an (indirect) bool, so convert
                // it back to the direct bool here.
                try self.convertToDirect(Type.bool, operand_id);
        };

        return switch (pred) {
            .is_null => blk: {
                // Invert condition
                const result_id = self.spv.allocId();
                try self.func.body.emit(self.spv.gpa, .OpLogicalNot, .{
                    .id_result_type = bool_ty_id,
                    .id_result = result_id,
                    .operand = is_non_null_id,
                });
                break :blk result_id;
            },
            .is_non_null => is_non_null_id,
        };
    }

    fn airIsErr(self: *NavGen, inst: Air.Inst.Index, pred: enum { is_err, is_non_err }) !?Id {
        const zcu = self.pt.zcu;
        const un_op = self.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
        const operand_id = try self.resolve(un_op);
        const err_union_ty = self.typeOf(un_op);

        if (err_union_ty.errorUnionSet(zcu).errorSetIsEmpty(zcu)) {
            return try self.constBool(pred == .is_non_err, .direct);
        }

        const payload_ty = err_union_ty.errorUnionPayload(zcu);
        const eu_layout = self.errorUnionLayout(payload_ty);
        const bool_ty_id = try self.resolveType(Type.bool, .direct);

        const error_id = if (!eu_layout.payload_has_bits)
            operand_id
        else
            try self.extractField(Type.anyerror, operand_id, eu_layout.errorFieldIndex());

        const result_id = self.spv.allocId();
        switch (pred) {
            inline else => |pred_ct| try self.func.body.emit(
                self.spv.gpa,
                switch (pred_ct) {
                    .is_err => .OpINotEqual,
                    .is_non_err => .OpIEqual,
                },
                .{
                    .id_result_type = bool_ty_id,
                    .id_result = result_id,
                    .operand_1 = error_id,
                    .operand_2 = try self.constInt(Type.anyerror, 0),
                },
            ),
        }
        return result_id;
    }

    fn airUnwrapOptional(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const optional_ty = self.typeOf(ty_op.operand);
        const payload_ty = self.typeOfIndex(inst);

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) return null;

        if (optional_ty.optionalReprIsPayload(zcu)) {
            return operand_id;
        }

        return try self.extractField(payload_ty, operand_id, 0);
    }

    fn airUnwrapOptionalPtr(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const optional_ty = operand_ty.childType(zcu);
        const payload_ty = optional_ty.optionalChild(zcu);
        const result_ty = self.typeOfIndex(inst);
        const result_ty_id = try self.resolveType(result_ty, .direct);

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            // There is no payload, but we still need to return a valid pointer.
            // We can just return anything here, so just return a pointer to the operand.
            return try self.bitCast(result_ty, operand_ty, operand_id);
        }

        if (optional_ty.optionalReprIsPayload(zcu)) {
            // They are the same value.
            return try self.bitCast(result_ty, operand_ty, operand_id);
        }

        return try self.accessChain(result_ty_id, operand_id, &.{0});
    }

    fn airWrapOptional(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const pt = self.pt;
        const zcu = pt.zcu;
        const ty_op = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_op;
        const payload_ty = self.typeOf(ty_op.operand);

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
            return try self.constBool(true, .indirect);
        }

        const operand_id = try self.resolve(ty_op.operand);

        const optional_ty = self.typeOfIndex(inst);
        if (optional_ty.optionalReprIsPayload(zcu)) {
            return operand_id;
        }

        const payload_id = try self.convertToIndirect(payload_ty, operand_id);
        const members = [_]Id{ payload_id, try self.constBool(true, .indirect) };
        const optional_ty_id = try self.resolveType(optional_ty, .direct);
        return try self.constructComposite(optional_ty_id, &members);
    }

    fn airSwitchBr(self: *NavGen, inst: Air.Inst.Index) !void {
        const pt = self.pt;
        const zcu = pt.zcu;
        const target = self.spv.target;
        const switch_br = self.air.unwrapSwitch(inst);
        const cond_ty = self.typeOf(switch_br.operand);
        const cond = try self.resolve(switch_br.operand);
        var cond_indirect = try self.convertToIndirect(cond_ty, cond);

        const cond_words: u32 = switch (cond_ty.zigTypeTag(zcu)) {
            .bool, .error_set => 1,
            .int => blk: {
                const bits = cond_ty.intInfo(zcu).bits;
                const backing_bits, const big_int = self.backingIntBits(bits);
                if (big_int) return self.todo("implement composite int switch", .{});
                break :blk if (backing_bits <= 32) 1 else 2;
            },
            .@"enum" => blk: {
                const int_ty = cond_ty.intTagType(zcu);
                const int_info = int_ty.intInfo(zcu);
                const backing_bits, const big_int = self.backingIntBits(int_info.bits);
                if (big_int) return self.todo("implement composite int switch", .{});
                break :blk if (backing_bits <= 32) 1 else 2;
            },
            .pointer => blk: {
                cond_indirect = try self.intFromPtr(cond_indirect);
                break :blk target.ptrBitWidth() / 32;
            },
            // TODO: Figure out which types apply here, and work around them as we can only do integers.
            else => return self.todo("implement switch for type {s}", .{@tagName(cond_ty.zigTypeTag(zcu))}),
        };

        const num_cases = switch_br.cases_len;

        // Compute the total number of arms that we need.
        // Zig switches are grouped by condition, so we need to loop through all of them
        const num_conditions = blk: {
            var num_conditions: u32 = 0;
            var it = switch_br.iterateCases();
            while (it.next()) |case| {
                if (case.ranges.len > 0) return self.todo("switch with ranges", .{});
                num_conditions += @intCast(case.items.len);
            }
            break :blk num_conditions;
        };

        // First, pre-allocate the labels for the cases.
        const case_labels = self.spv.allocIds(num_cases);
        // We always need the default case - if zig has none, we will generate unreachable there.
        const default = self.spv.allocId();

        const merge_label = switch (self.control_flow) {
            .structured => self.spv.allocId(),
            .unstructured => null,
        };

        if (self.control_flow == .structured) {
            try self.func.body.emit(self.spv.gpa, .OpSelectionMerge, .{
                .merge_block = merge_label.?,
                .selection_control = .{},
            });
        }

        // Emit the instruction before generating the blocks.
        try self.func.body.emitRaw(self.spv.gpa, .OpSwitch, 2 + (cond_words + 1) * num_conditions);
        self.func.body.writeOperand(Id, cond_indirect);
        self.func.body.writeOperand(Id, default);

        // Emit each of the cases
        {
            var it = switch_br.iterateCases();
            while (it.next()) |case| {
                // SPIR-V needs a literal here, which' width depends on the case condition.
                const label = case_labels.at(case.idx);

                for (case.items) |item| {
                    const value = (try self.air.value(item, pt)) orelse unreachable;
                    const int_val: u64 = switch (cond_ty.zigTypeTag(zcu)) {
                        .bool, .int => if (cond_ty.isSignedInt(zcu)) @bitCast(value.toSignedInt(zcu)) else value.toUnsignedInt(zcu),
                        .@"enum" => blk: {
                            // TODO: figure out of cond_ty is correct (something with enum literals)
                            break :blk (try value.intFromEnum(cond_ty, pt)).toUnsignedInt(zcu); // TODO: composite integer constants
                        },
                        .error_set => value.getErrorInt(zcu),
                        .pointer => value.toUnsignedInt(zcu),
                        else => unreachable,
                    };
                    const int_lit: spec.LiteralContextDependentNumber = switch (cond_words) {
                        1 => .{ .uint32 = @intCast(int_val) },
                        2 => .{ .uint64 = int_val },
                        else => unreachable,
                    };
                    self.func.body.writeOperand(spec.LiteralContextDependentNumber, int_lit);
                    self.func.body.writeOperand(Id, label);
                }
            }
        }

        var incoming_structured_blocks: std.ArrayListUnmanaged(ControlFlow.Structured.Block.Incoming) = .empty;
        defer incoming_structured_blocks.deinit(self.gpa);

        if (self.control_flow == .structured) {
            try incoming_structured_blocks.ensureUnusedCapacity(self.gpa, num_cases + 1);
        }

        // Now, finally, we can start emitting each of the cases.
        var it = switch_br.iterateCases();
        while (it.next()) |case| {
            const label = case_labels.at(case.idx);

            try self.beginSpvBlock(label);

            switch (self.control_flow) {
                .structured => {
                    const next_block = try self.genStructuredBody(.selection, case.body);
                    incoming_structured_blocks.appendAssumeCapacity(.{
                        .src_label = self.current_block_label,
                        .next_block = next_block,
                    });
                    try self.func.body.emitBranch(self.spv.gpa, merge_label.?);
                },
                .unstructured => {
                    try self.genBody(case.body);
                },
            }
        }

        const else_body = it.elseBody();
        try self.beginSpvBlock(default);
        if (else_body.len != 0) {
            switch (self.control_flow) {
                .structured => {
                    const next_block = try self.genStructuredBody(.selection, else_body);
                    incoming_structured_blocks.appendAssumeCapacity(.{
                        .src_label = self.current_block_label,
                        .next_block = next_block,
                    });
                    try self.func.body.emitBranch(self.spv.gpa, merge_label.?);
                },
                .unstructured => {
                    try self.genBody(else_body);
                },
            }
        } else {
            try self.func.body.emit(self.spv.gpa, .OpUnreachable, {});
        }

        if (self.control_flow == .structured) {
            try self.beginSpvBlock(merge_label.?);
            const next_block = try self.structuredNextBlock(incoming_structured_blocks.items);
            try self.structuredBreak(next_block);
        }
    }

    fn airUnreach(self: *NavGen) !void {
        try self.func.body.emit(self.spv.gpa, .OpUnreachable, {});
    }

    fn airDbgStmt(self: *NavGen, inst: Air.Inst.Index) !void {
        const pt = self.pt;
        const zcu = pt.zcu;
        const dbg_stmt = self.air.instructions.items(.data)[@intFromEnum(inst)].dbg_stmt;
        const path = zcu.navFileScope(self.owner_nav).sub_file_path;
        try self.func.body.emit(self.spv.gpa, .OpLine, .{
            .file = try self.spv.resolveString(path),
            .line = self.base_line + dbg_stmt.line + 1,
            .column = dbg_stmt.column + 1,
        });
    }

    fn airDbgInlineBlock(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const inst_datas = self.air.instructions.items(.data);
        const extra = self.air.extraData(Air.DbgInlineBlock, inst_datas[@intFromEnum(inst)].ty_pl.payload);
        const old_base_line = self.base_line;
        defer self.base_line = old_base_line;
        self.base_line = zcu.navSrcLine(zcu.funcInfo(extra.data.func).owner_nav);
        return self.lowerBlock(inst, @ptrCast(self.air.extra.items[extra.end..][0..extra.data.body_len]));
    }

    fn airDbgVar(self: *NavGen, inst: Air.Inst.Index) !void {
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const target_id = try self.resolve(pl_op.operand);
        const name: Air.NullTerminatedString = @enumFromInt(pl_op.payload);
        try self.spv.debugName(target_id, name.toSlice(self.air));
    }

    fn airAssembly(self: *NavGen, inst: Air.Inst.Index) !?Id {
        const zcu = self.pt.zcu;
        const ty_pl = self.air.instructions.items(.data)[@intFromEnum(inst)].ty_pl;
        const extra = self.air.extraData(Air.Asm, ty_pl.payload);

        const is_volatile = extra.data.flags.is_volatile;
        const outputs_len = extra.data.flags.outputs_len;

        if (!is_volatile and self.liveness.isUnused(inst)) return null;

        var extra_i: usize = extra.end;
        const outputs: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra_i..][0..outputs_len]);
        extra_i += outputs.len;
        const inputs: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra_i..][0..extra.data.inputs_len]);
        extra_i += inputs.len;

        if (outputs.len > 1) {
            return self.todo("implement inline asm with more than 1 output", .{});
        }

        var as: SpvAssembler = .{
            .gpa = self.gpa,
            .spv = self.spv,
            .func = &self.func,
        };
        defer as.deinit();

        var output_extra_i = extra_i;
        for (outputs) |output| {
            if (output != .none) {
                return self.todo("implement inline asm with non-returned output", .{});
            }
            const extra_bytes = std.mem.sliceAsBytes(self.air.extra.items[extra_i..]);
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra.items[extra_i..]), 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;
            // TODO: Record output and use it somewhere.
        }

        for (inputs) |input| {
            const extra_bytes = std.mem.sliceAsBytes(self.air.extra.items[extra_i..]);
            const constraint = std.mem.sliceTo(extra_bytes, 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            const input_ty = self.typeOf(input);

            if (std.mem.eql(u8, constraint, "c")) {
                // constant
                const val = (try self.air.value(input, self.pt)) orelse {
                    return self.fail("assembly inputs with 'c' constraint have to be compile-time known", .{});
                };

                // TODO: This entire function should be handled a bit better...
                const ip = &zcu.intern_pool;
                switch (ip.indexToKey(val.toIntern())) {
                    .int_type,
                    .ptr_type,
                    .array_type,
                    .vector_type,
                    .opt_type,
                    .anyframe_type,
                    .error_union_type,
                    .simple_type,
                    .struct_type,
                    .union_type,
                    .opaque_type,
                    .enum_type,
                    .func_type,
                    .error_set_type,
                    .inferred_error_set_type,
                    => unreachable, // types, not values

                    .undef => return self.fail("assembly input with 'c' constraint cannot be undefined", .{}),

                    .int => try as.value_map.put(as.gpa, name, .{ .constant = @intCast(val.toUnsignedInt(zcu)) }),
                    .enum_literal => |str| try as.value_map.put(as.gpa, name, .{ .string = str.toSlice(ip) }),

                    else => unreachable, // TODO
                }
            } else if (std.mem.eql(u8, constraint, "t")) {
                // type
                if (input_ty.zigTypeTag(zcu) == .type) {
                    // This assembly input is a type instead of a value.
                    // That's fine for now, just make sure to resolve it as such.
                    const val = (try self.air.value(input, self.pt)).?;
                    const ty_id = try self.resolveType(val.toType(), .direct);
                    try as.value_map.put(as.gpa, name, .{ .ty = ty_id });
                } else {
                    const ty_id = try self.resolveType(input_ty, .direct);
                    try as.value_map.put(as.gpa, name, .{ .ty = ty_id });
                }
            } else {
                if (input_ty.zigTypeTag(zcu) == .type) {
                    return self.fail("use the 't' constraint to supply types to SPIR-V inline assembly", .{});
                }

                const val_id = try self.resolve(input);
                try as.value_map.put(as.gpa, name, .{ .value = val_id });
            }
        }

        // TODO: do something with clobbers
        _ = extra.data.clobbers;

        const asm_source = std.mem.sliceAsBytes(self.air.extra.items[extra_i..])[0..extra.data.source_len];

        as.assemble(asm_source) catch |err| switch (err) {
            error.AssembleFail => {
                // TODO: For now the compiler only supports a single error message per decl,
                // so to translate the possible multiple errors from the assembler, emit
                // them as notes here.
                // TODO: Translate proper error locations.
                assert(as.errors.items.len != 0);
                assert(self.error_msg == null);
                const src_loc = zcu.navSrcLoc(self.owner_nav);
                self.error_msg = try Zcu.ErrorMsg.create(zcu.gpa, src_loc, "failed to assemble SPIR-V inline assembly", .{});
                const notes = try zcu.gpa.alloc(Zcu.ErrorMsg, as.errors.items.len);

                // Sub-scope to prevent `return error.CodegenFail` from running the errdefers.
                {
                    errdefer zcu.gpa.free(notes);
                    var i: usize = 0;
                    errdefer for (notes[0..i]) |*note| {
                        note.deinit(zcu.gpa);
                    };

                    while (i < as.errors.items.len) : (i += 1) {
                        notes[i] = try Zcu.ErrorMsg.init(zcu.gpa, src_loc, "{s}", .{as.errors.items[i].msg});
                    }
                }
                self.error_msg.?.notes = notes;
                return error.CodegenFail;
            },
            else => |others| return others,
        };

        for (outputs) |output| {
            _ = output;
            const extra_bytes = std.mem.sliceAsBytes(self.air.extra.items[output_extra_i..]);
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra.items[output_extra_i..]), 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            output_extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            const result = as.value_map.get(name) orelse return {
                return self.fail("invalid asm output '{s}'", .{name});
            };

            switch (result) {
                .just_declared, .unresolved_forward_reference => unreachable,
                .ty => return self.fail("cannot return spir-v type as value from assembly", .{}),
                .value => |ref| return ref,
                .constant, .string => return self.fail("cannot return constant from assembly", .{}),
            }

            // TODO: Multiple results
            // TODO: Check that the output type from assembly is the same as the type actually expected by Zig.
        }

        return null;
    }

    fn airCall(self: *NavGen, inst: Air.Inst.Index, modifier: std.builtin.CallModifier) !?Id {
        _ = modifier;

        const pt = self.pt;
        const zcu = pt.zcu;
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const extra = self.air.extraData(Air.Call, pl_op.payload);
        const args: []const Air.Inst.Ref = @ptrCast(self.air.extra.items[extra.end..][0..extra.data.args_len]);
        const callee_ty = self.typeOf(pl_op.operand);
        const zig_fn_ty = switch (callee_ty.zigTypeTag(zcu)) {
            .@"fn" => callee_ty,
            .pointer => return self.fail("cannot call function pointers", .{}),
            else => unreachable,
        };
        const fn_info = zcu.typeToFunc(zig_fn_ty).?;
        const return_type = fn_info.return_type;

        const result_type_id = try self.resolveFnReturnType(Type.fromInterned(return_type));
        const result_id = self.spv.allocId();
        const callee_id = try self.resolve(pl_op.operand);

        comptime assert(zig_call_abi_ver == 3);
        const params = try self.gpa.alloc(spec.Id, args.len);
        defer self.gpa.free(params);
        var n_params: usize = 0;
        for (args) |arg| {
            // Note: resolve() might emit instructions, so we need to call it
            // before starting to emit OpFunctionCall instructions. Hence the
            // temporary params buffer.
            const arg_ty = self.typeOf(arg);
            if (!arg_ty.hasRuntimeBitsIgnoreComptime(zcu)) continue;
            const arg_id = try self.resolve(arg);

            params[n_params] = arg_id;
            n_params += 1;
        }

        try self.func.body.emit(self.spv.gpa, .OpFunctionCall, .{
            .id_result_type = result_type_id,
            .id_result = result_id,
            .function = callee_id,
            .id_ref_3 = params[0..n_params],
        });

        if (self.liveness.isUnused(inst) or !Type.fromInterned(return_type).hasRuntimeBitsIgnoreComptime(zcu)) {
            return null;
        }

        return result_id;
    }

    fn builtin3D(self: *NavGen, result_ty: Type, builtin: spec.BuiltIn, dimension: u32, out_of_range_value: anytype) !Id {
        if (dimension >= 3) {
            return try self.constInt(result_ty, out_of_range_value);
        }
        const vec_ty = try self.pt.vectorType(.{
            .len = 3,
            .child = result_ty.toIntern(),
        });
        const ptr_ty_id = try self.ptrType(vec_ty, .input, .indirect);
        const spv_decl_index = try self.spv.builtin(ptr_ty_id, builtin);
        try self.func.decl_deps.put(self.spv.gpa, spv_decl_index, {});
        const ptr = self.spv.declPtr(spv_decl_index).result_id;
        const vec = try self.load(vec_ty, ptr, .{});
        return try self.extractVectorComponent(result_ty, vec, dimension);
    }

    fn airWorkItemId(self: *NavGen, inst: Air.Inst.Index) !?Id {
        if (self.liveness.isUnused(inst)) return null;
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const dimension = pl_op.payload;
        // TODO: Should we make these builtins return usize?
        const result_id = try self.builtin3D(Type.u64, .local_invocation_id, dimension, 0);
        const tmp = Temporary.init(Type.u64, result_id);
        const result = try self.buildConvert(Type.u32, tmp);
        return try result.materialize(self);
    }

    fn airWorkGroupSize(self: *NavGen, inst: Air.Inst.Index) !?Id {
        if (self.liveness.isUnused(inst)) return null;
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const dimension = pl_op.payload;
        // TODO: Should we make these builtins return usize?
        const result_id = try self.builtin3D(Type.u64, .workgroup_size, dimension, 0);
        const tmp = Temporary.init(Type.u64, result_id);
        const result = try self.buildConvert(Type.u32, tmp);
        return try result.materialize(self);
    }

    fn airWorkGroupId(self: *NavGen, inst: Air.Inst.Index) !?Id {
        if (self.liveness.isUnused(inst)) return null;
        const pl_op = self.air.instructions.items(.data)[@intFromEnum(inst)].pl_op;
        const dimension = pl_op.payload;
        // TODO: Should we make these builtins return usize?
        const result_id = try self.builtin3D(Type.u64, .workgroup_id, dimension, 0);
        const tmp = Temporary.init(Type.u64, result_id);
        const result = try self.buildConvert(Type.u32, tmp);
        return try result.materialize(self);
    }

    fn typeOf(self: *NavGen, inst: Air.Inst.Ref) Type {
        const zcu = self.pt.zcu;
        return self.air.typeOf(inst, &zcu.intern_pool);
    }

    fn typeOfIndex(self: *NavGen, inst: Air.Inst.Index) Type {
        const zcu = self.pt.zcu;
        return self.air.typeOfIndex(inst, &zcu.intern_pool);
    }
};
