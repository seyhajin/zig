//! Manages `zig-cache` directories.
//! This is not a general-purpose cache. It is designed to be fast and simple,
//! not to withstand attacks using specially-crafted input.

const Cache = @This();
const std = @import("std");
const builtin = @import("builtin");
const crypto = std.crypto;
const fs = std.fs;
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.cache);

gpa: Allocator,
manifest_dir: fs.Dir,
hash: HashHelper = .{},
/// This value is accessed from multiple threads, protected by mutex.
recent_problematic_timestamp: i128 = 0,
mutex: std.Thread.Mutex = .{},

/// A set of strings such as the zig library directory or project source root, which
/// are stripped from the file paths before putting into the cache. They
/// are replaced with single-character indicators. This is not to save
/// space but to eliminate absolute file paths. This improves portability
/// and usefulness of the cache for advanced use cases.
prefixes_buffer: [4]Directory = undefined,
prefixes_len: usize = 0,

pub const Path = @import("Cache/Path.zig");
pub const Directory = @import("Cache/Directory.zig");
pub const DepTokenizer = @import("Cache/DepTokenizer.zig");

pub fn addPrefix(cache: *Cache, directory: Directory) void {
    cache.prefixes_buffer[cache.prefixes_len] = directory;
    cache.prefixes_len += 1;
}

/// Be sure to call `Manifest.deinit` after successful initialization.
pub fn obtain(cache: *Cache) Manifest {
    return .{
        .cache = cache,
        .hash = cache.hash,
        .manifest_file = null,
        .manifest_dirty = false,
        .hex_digest = undefined,
    };
}

pub fn prefixes(cache: *const Cache) []const Directory {
    return cache.prefixes_buffer[0..cache.prefixes_len];
}

const PrefixedPath = struct {
    prefix: u8,
    sub_path: []const u8,

    fn eql(a: PrefixedPath, b: PrefixedPath) bool {
        return a.prefix == b.prefix and std.mem.eql(u8, a.sub_path, b.sub_path);
    }

    fn hash(pp: PrefixedPath) u32 {
        return @truncate(std.hash.Wyhash.hash(pp.prefix, pp.sub_path));
    }
};

fn findPrefix(cache: *const Cache, file_path: []const u8) !PrefixedPath {
    const gpa = cache.gpa;
    const resolved_path = try fs.path.resolve(gpa, &.{file_path});
    errdefer gpa.free(resolved_path);
    return findPrefixResolved(cache, resolved_path);
}

/// Takes ownership of `resolved_path` on success.
fn findPrefixResolved(cache: *const Cache, resolved_path: []u8) !PrefixedPath {
    const gpa = cache.gpa;
    const prefixes_slice = cache.prefixes();
    var i: u8 = 1; // Start at 1 to skip over checking the null prefix.
    while (i < prefixes_slice.len) : (i += 1) {
        const p = prefixes_slice[i].path.?;
        const sub_path = getPrefixSubpath(gpa, p, resolved_path) catch |err| switch (err) {
            error.NotASubPath => continue,
            else => |e| return e,
        };
        // Free the resolved path since we're not going to return it
        gpa.free(resolved_path);
        return PrefixedPath{
            .prefix = i,
            .sub_path = sub_path,
        };
    }

    return PrefixedPath{
        .prefix = 0,
        .sub_path = resolved_path,
    };
}

fn getPrefixSubpath(allocator: Allocator, prefix: []const u8, path: []u8) ![]u8 {
    const relative = try fs.path.relative(allocator, prefix, path);
    errdefer allocator.free(relative);
    var component_iterator = fs.path.NativeComponentIterator.init(relative) catch {
        return error.NotASubPath;
    };
    if (component_iterator.root() != null) {
        return error.NotASubPath;
    }
    const first_component = component_iterator.first();
    if (first_component != null and std.mem.eql(u8, first_component.?.name, "..")) {
        return error.NotASubPath;
    }
    return relative;
}

/// This is 128 bits - Even with 2^54 cache entries, the probably of a collision would be under 10^-6
pub const bin_digest_len = 16;
pub const hex_digest_len = bin_digest_len * 2;
pub const BinDigest = [bin_digest_len]u8;
pub const HexDigest = [hex_digest_len]u8;

/// This is currently just an arbitrary non-empty string that can't match another manifest line.
const manifest_header = "0";
const manifest_file_size_max = 100 * 1024 * 1024;

/// The type used for hashing file contents. Currently, this is SipHash128(1, 3), because it
/// provides enough collision resistance for the Manifest use cases, while being one of our
/// fastest options right now.
pub const Hasher = crypto.auth.siphash.SipHash128(1, 3);

/// Initial state with random bytes, that can be copied.
/// Refresh this with new random bytes when the manifest
/// format is modified in a non-backwards-compatible way.
pub const hasher_init: Hasher = Hasher.init(&.{
    0x33, 0x52, 0xa2, 0x84,
    0xcf, 0x17, 0x56, 0x57,
    0x01, 0xbb, 0xcd, 0xe4,
    0x77, 0xd6, 0xf0, 0x60,
});

pub const File = struct {
    prefixed_path: PrefixedPath,
    max_file_size: ?usize,
    /// Populated if the user calls `addOpenedFile`.
    /// The handle is not owned here.
    handle: ?fs.File,
    stat: Stat,
    bin_digest: BinDigest,
    contents: ?[]const u8,

    pub const Stat = struct {
        inode: fs.File.INode,
        size: u64,
        mtime: i128,

        pub fn fromFs(fs_stat: fs.File.Stat) Stat {
            return .{
                .inode = fs_stat.inode,
                .size = fs_stat.size,
                .mtime = fs_stat.mtime,
            };
        }
    };

    pub fn deinit(self: *File, gpa: Allocator) void {
        gpa.free(self.prefixed_path.sub_path);
        if (self.contents) |contents| {
            gpa.free(contents);
            self.contents = null;
        }
        self.* = undefined;
    }

    pub fn updateMaxSize(file: *File, new_max_size: ?usize) void {
        const new = new_max_size orelse return;
        file.max_file_size = if (file.max_file_size) |old| @max(old, new) else new;
    }

    pub fn updateHandle(file: *File, new_handle: ?fs.File) void {
        const handle = new_handle orelse return;
        file.handle = handle;
    }
};

pub const HashHelper = struct {
    hasher: Hasher = hasher_init,

    /// Record a slice of bytes as a dependency of the process being cached.
    pub fn addBytes(hh: *HashHelper, bytes: []const u8) void {
        hh.hasher.update(mem.asBytes(&bytes.len));
        hh.hasher.update(bytes);
    }

    pub fn addOptionalBytes(hh: *HashHelper, optional_bytes: ?[]const u8) void {
        hh.add(optional_bytes != null);
        hh.addBytes(optional_bytes orelse return);
    }

    pub fn addListOfBytes(hh: *HashHelper, list_of_bytes: []const []const u8) void {
        hh.add(list_of_bytes.len);
        for (list_of_bytes) |bytes| hh.addBytes(bytes);
    }

    pub fn addOptionalListOfBytes(hh: *HashHelper, optional_list_of_bytes: ?[]const []const u8) void {
        hh.add(optional_list_of_bytes != null);
        hh.addListOfBytes(optional_list_of_bytes orelse return);
    }

    /// Convert the input value into bytes and record it as a dependency of the process being cached.
    pub fn add(hh: *HashHelper, x: anytype) void {
        switch (@TypeOf(x)) {
            std.SemanticVersion => {
                hh.add(x.major);
                hh.add(x.minor);
                hh.add(x.patch);
            },
            std.Target.Os.TaggedVersionRange => {
                switch (x) {
                    .hurd => |hurd| {
                        hh.add(hurd.range.min);
                        hh.add(hurd.range.max);
                        hh.add(hurd.glibc);
                    },
                    .linux => |linux| {
                        hh.add(linux.range.min);
                        hh.add(linux.range.max);
                        hh.add(linux.glibc);
                        hh.add(linux.android);
                    },
                    .windows => |windows| {
                        hh.add(windows.min);
                        hh.add(windows.max);
                    },
                    .semver => |semver| {
                        hh.add(semver.min);
                        hh.add(semver.max);
                    },
                    .none => {},
                }
            },
            std.zig.BuildId => switch (x) {
                .none, .fast, .uuid, .sha1, .md5 => hh.add(std.meta.activeTag(x)),
                .hexstring => |hex_string| hh.addBytes(hex_string.toSlice()),
            },
            else => switch (@typeInfo(@TypeOf(x))) {
                .bool, .int, .@"enum", .array => hh.addBytes(mem.asBytes(&x)),
                else => @compileError("unable to hash type " ++ @typeName(@TypeOf(x))),
            },
        }
    }

    pub fn addOptional(hh: *HashHelper, optional: anytype) void {
        hh.add(optional != null);
        hh.add(optional orelse return);
    }

    /// Returns a hex encoded hash of the inputs, without modifying state.
    pub fn peek(hh: HashHelper) [hex_digest_len]u8 {
        var copy = hh;
        return copy.final();
    }

    pub fn peekBin(hh: HashHelper) BinDigest {
        var copy = hh;
        var bin_digest: BinDigest = undefined;
        copy.hasher.final(&bin_digest);
        return bin_digest;
    }

    /// Returns a hex encoded hash of the inputs, mutating the state of the hasher.
    pub fn final(hh: *HashHelper) HexDigest {
        var bin_digest: BinDigest = undefined;
        hh.hasher.final(&bin_digest);
        return binToHex(bin_digest);
    }

    pub fn oneShot(bytes: []const u8) [hex_digest_len]u8 {
        var hasher: Hasher = hasher_init;
        hasher.update(bytes);
        var bin_digest: BinDigest = undefined;
        hasher.final(&bin_digest);
        return binToHex(bin_digest);
    }
};

pub fn binToHex(bin_digest: BinDigest) HexDigest {
    var out_digest: HexDigest = undefined;
    var w: std.io.Writer = .fixed(&out_digest);
    w.printHex(&bin_digest, .lower) catch unreachable;
    return out_digest;
}

pub const Lock = struct {
    manifest_file: fs.File,

    pub fn release(lock: *Lock) void {
        if (builtin.os.tag == .windows) {
            // Windows does not guarantee that locks are immediately unlocked when
            // the file handle is closed. See LockFileEx documentation.
            lock.manifest_file.unlock();
        }

        lock.manifest_file.close();
        lock.* = undefined;
    }
};

pub const Manifest = struct {
    cache: *Cache,
    /// Current state for incremental hashing.
    hash: HashHelper,
    manifest_file: ?fs.File,
    manifest_dirty: bool,
    /// Set this flag to true before calling hit() in order to indicate that
    /// upon a cache hit, the code using the cache will not modify the files
    /// within the cache directory. This allows multiple processes to utilize
    /// the same cache directory at the same time.
    want_shared_lock: bool = true,
    have_exclusive_lock: bool = false,
    // Indicate that we want isProblematicTimestamp to perform a filesystem write in
    // order to obtain a problematic timestamp for the next call. Calls after that
    // will then use the same timestamp, to avoid unnecessary filesystem writes.
    want_refresh_timestamp: bool = true,
    files: Files = .{},
    hex_digest: HexDigest,
    diagnostic: Diagnostic = .none,
    /// Keeps track of the last time we performed a file system write to observe
    /// what time the file system thinks it is, according to its own granularity.
    recent_problematic_timestamp: i128 = 0,

    pub const Diagnostic = union(enum) {
        none,
        manifest_create: fs.File.OpenError,
        manifest_read: fs.File.ReadError,
        manifest_lock: fs.File.LockError,
        file_open: FileOp,
        file_stat: FileOp,
        file_read: FileOp,
        file_hash: FileOp,

        pub const FileOp = struct {
            file_index: usize,
            err: anyerror,
        };
    };

    pub const Files = std.ArrayHashMapUnmanaged(File, void, FilesContext, false);

    pub const FilesContext = struct {
        pub fn hash(fc: FilesContext, file: File) u32 {
            _ = fc;
            return file.prefixed_path.hash();
        }

        pub fn eql(fc: FilesContext, a: File, b: File, b_index: usize) bool {
            _ = fc;
            _ = b_index;
            return a.prefixed_path.eql(b.prefixed_path);
        }
    };

    const FilesAdapter = struct {
        pub fn eql(context: @This(), a: PrefixedPath, b: File, b_index: usize) bool {
            _ = context;
            _ = b_index;
            return a.eql(b.prefixed_path);
        }

        pub fn hash(context: @This(), key: PrefixedPath) u32 {
            _ = context;
            return key.hash();
        }
    };

    /// Add a file as a dependency of process being cached. When `hit` is
    /// called, the file's contents will be checked to ensure that it matches
    /// the contents from previous times.
    ///
    /// Max file size will be used to determine the amount of space the file contents
    /// are allowed to take up in memory. If max_file_size is null, then the contents
    /// will not be loaded into memory.
    ///
    /// Returns the index of the entry in the `files` array list. You can use it
    /// to access the contents of the file after calling `hit()` like so:
    ///
    /// ```
    /// var file_contents = cache_hash.files.keys()[file_index].contents.?;
    /// ```
    pub fn addFilePath(m: *Manifest, file_path: Path, max_file_size: ?usize) !usize {
        return addOpenedFile(m, file_path, null, max_file_size);
    }

    /// Same as `addFilePath` except the file has already been opened.
    pub fn addOpenedFile(m: *Manifest, path: Path, handle: ?fs.File, max_file_size: ?usize) !usize {
        const gpa = m.cache.gpa;
        try m.files.ensureUnusedCapacity(gpa, 1);
        const resolved_path = try fs.path.resolve(gpa, &.{
            path.root_dir.path orelse ".",
            path.subPathOrDot(),
        });
        errdefer gpa.free(resolved_path);
        const prefixed_path = try m.cache.findPrefixResolved(resolved_path);
        return addFileInner(m, prefixed_path, handle, max_file_size);
    }

    /// Deprecated; use `addFilePath`.
    pub fn addFile(self: *Manifest, file_path: []const u8, max_file_size: ?usize) !usize {
        assert(self.manifest_file == null);

        const gpa = self.cache.gpa;
        try self.files.ensureUnusedCapacity(gpa, 1);
        const prefixed_path = try self.cache.findPrefix(file_path);
        errdefer gpa.free(prefixed_path.sub_path);

        return addFileInner(self, prefixed_path, null, max_file_size);
    }

    fn addFileInner(self: *Manifest, prefixed_path: PrefixedPath, handle: ?fs.File, max_file_size: ?usize) usize {
        const gop = self.files.getOrPutAssumeCapacityAdapted(prefixed_path, FilesAdapter{});
        if (gop.found_existing) {
            self.cache.gpa.free(prefixed_path.sub_path);
            gop.key_ptr.updateMaxSize(max_file_size);
            gop.key_ptr.updateHandle(handle);
            return gop.index;
        }
        gop.key_ptr.* = .{
            .prefixed_path = prefixed_path,
            .contents = null,
            .max_file_size = max_file_size,
            .stat = undefined,
            .bin_digest = undefined,
            .handle = handle,
        };

        self.hash.add(prefixed_path.prefix);
        self.hash.addBytes(prefixed_path.sub_path);

        return gop.index;
    }

    /// Deprecated, use `addOptionalFilePath`.
    pub fn addOptionalFile(self: *Manifest, optional_file_path: ?[]const u8) !void {
        self.hash.add(optional_file_path != null);
        const file_path = optional_file_path orelse return;
        _ = try self.addFile(file_path, null);
    }

    pub fn addOptionalFilePath(self: *Manifest, optional_file_path: ?Path) !void {
        self.hash.add(optional_file_path != null);
        const file_path = optional_file_path orelse return;
        _ = try self.addFilePath(file_path, null);
    }

    pub fn addListOfFiles(self: *Manifest, list_of_files: []const []const u8) !void {
        self.hash.add(list_of_files.len);
        for (list_of_files) |file_path| {
            _ = try self.addFile(file_path, null);
        }
    }

    pub fn addDepFile(self: *Manifest, dir: fs.Dir, dep_file_basename: []const u8) !void {
        assert(self.manifest_file == null);
        return self.addDepFileMaybePost(dir, dep_file_basename);
    }

    pub const HitError = error{
        /// Unable to check the cache for a reason that has been recorded into
        /// the `diagnostic` field.
        CacheCheckFailed,
        /// A cache manifest file exists however it could not be parsed.
        InvalidFormat,
        OutOfMemory,
    };

    /// Check the cache to see if the input exists in it. If it exists, returns `true`.
    /// A hex encoding of its hash is available by calling `final`.
    ///
    /// This function will also acquire an exclusive lock to the manifest file. This means
    /// that a process holding a Manifest will block any other process attempting to
    /// acquire the lock. If `want_shared_lock` is `true`, a cache hit guarantees the
    /// manifest file to be locked in shared mode, and a cache miss guarantees the manifest
    /// file to be locked in exclusive mode.
    ///
    /// The lock on the manifest file is released when `deinit` is called. As another
    /// option, one may call `toOwnedLock` to obtain a smaller object which can represent
    /// the lock. `deinit` is safe to call whether or not `toOwnedLock` has been called.
    pub fn hit(self: *Manifest) HitError!bool {
        assert(self.manifest_file == null);

        self.diagnostic = .none;

        const ext = ".txt";
        var manifest_file_path: [hex_digest_len + ext.len]u8 = undefined;

        var bin_digest: BinDigest = undefined;
        self.hash.hasher.final(&bin_digest);

        self.hex_digest = binToHex(bin_digest);

        @memcpy(manifest_file_path[0..self.hex_digest.len], &self.hex_digest);
        manifest_file_path[hex_digest_len..][0..ext.len].* = ext.*;

        // We'll try to open the cache with an exclusive lock, but if that would block
        // and `want_shared_lock` is set, a shared lock might be sufficient, so we'll
        // open with a shared lock instead.
        while (true) {
            if (self.cache.manifest_dir.createFile(&manifest_file_path, .{
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = self.want_shared_lock,
            })) |manifest_file| {
                self.manifest_file = manifest_file;
                self.have_exclusive_lock = true;
                break;
            } else |err| switch (err) {
                error.WouldBlock => {
                    self.manifest_file = self.cache.manifest_dir.openFile(&manifest_file_path, .{
                        .mode = .read_write,
                        .lock = .shared,
                    }) catch |e| {
                        self.diagnostic = .{ .manifest_create = e };
                        return error.CacheCheckFailed;
                    };
                    break;
                },
                error.FileNotFound => {
                    // There are no dir components, so the only possibility
                    // should be that the directory behind the handle has been
                    // deleted, however we have observed on macOS two processes
                    // racing to do openat() with O_CREAT manifest in ENOENT.
                    //
                    // As a workaround, we retry with exclusive=true which
                    // disambiguates by returning EEXIST, indicating original
                    // failure was a race, or ENOENT, indicating deletion of
                    // the directory of our open handle.
                    if (builtin.os.tag != .macos) {
                        self.diagnostic = .{ .manifest_create = error.FileNotFound };
                        return error.CacheCheckFailed;
                    }

                    if (self.cache.manifest_dir.createFile(&manifest_file_path, .{
                        .read = true,
                        .truncate = false,
                        .lock = .exclusive,
                        .lock_nonblocking = self.want_shared_lock,
                        .exclusive = true,
                    })) |manifest_file| {
                        self.manifest_file = manifest_file;
                        self.have_exclusive_lock = true;
                        break;
                    } else |excl_err| switch (excl_err) {
                        error.WouldBlock, error.PathAlreadyExists => continue,
                        error.FileNotFound => {
                            self.diagnostic = .{ .manifest_create = error.FileNotFound };
                            return error.CacheCheckFailed;
                        },
                        else => |e| {
                            self.diagnostic = .{ .manifest_create = e };
                            return error.CacheCheckFailed;
                        },
                    }
                },
                else => |e| {
                    self.diagnostic = .{ .manifest_create = e };
                    return error.CacheCheckFailed;
                },
            }
        }

        self.want_refresh_timestamp = true;

        const input_file_count = self.files.entries.len;

        // We're going to construct a second hash. Its input will begin with the digest we've
        // already computed (`bin_digest`), and then it'll have the digests of each input file,
        // including "post" files (see `addFilePost`). If this is a hit, we learn the set of "post"
        // files from the manifest on disk. If this is a miss, we'll learn those from future calls
        // to `addFilePost` etc. As such, the state of `self.hash.hasher` after this function
        // depends on whether this is a hit or a miss.
        //
        // If we return `true` indicating a cache hit, then `self.hash.hasher` must already include
        // the digests of the "post" files, so the caller can call `final`. Otherwise, on a cache
        // miss, `self.hash.hasher` will include the digests of all non-"post" files -- that is,
        // the ones we've already been told about. The rest will be discovered through calls to
        // `addFilePost` etc, which will update the hasher. After all files are added, the user can
        // use `final`, and will at some point `writeManifest` the file list to disk.

        self.hash.hasher = hasher_init;
        self.hash.hasher.update(&bin_digest);

        hit: {
            const file_digests_populated: usize = digests: {
                switch (try self.hitWithCurrentLock()) {
                    .hit => break :hit,
                    .miss => |m| if (!try self.upgradeToExclusiveLock()) {
                        break :digests m.file_digests_populated;
                    },
                }
                // We've just had a miss with the shared lock, and upgraded to an exclusive lock. Someone
                // else might have modified the digest, so we need to check again before deciding to miss.
                // Before trying again, we must reset `self.hash.hasher` and `self.files`.
                // This is basically just the first half of `unhit`.
                self.hash.hasher = hasher_init;
                self.hash.hasher.update(&bin_digest);
                while (self.files.count() != input_file_count) {
                    var file = self.files.pop().?;
                    file.key.deinit(self.cache.gpa);
                }
                switch (try self.hitWithCurrentLock()) {
                    .hit => break :hit,
                    .miss => |m| break :digests m.file_digests_populated,
                }
            };

            // This is a guaranteed cache miss. We're almost ready to return `false`, but there's a
            // little bookkeeping to do first. The first `file_digests_populated` entries in `files`
            // have their `bin_digest` populated; there may be some left in `input_file_count` which
            // we'll need to populate ourselves. Other than that, this is basically `unhit`.
            self.manifest_dirty = true;
            self.hash.hasher = hasher_init;
            self.hash.hasher.update(&bin_digest);
            while (self.files.count() != input_file_count) {
                var file = self.files.pop().?;
                file.key.deinit(self.cache.gpa);
            }
            for (self.files.keys(), 0..) |*file, idx| {
                if (idx < file_digests_populated) {
                    // `bin_digest` is already populated by `hitWithCurrentLock`, so we can use it directly.
                    self.hash.hasher.update(&file.bin_digest);
                } else {
                    self.populateFileHash(file) catch |err| {
                        self.diagnostic = .{ .file_hash = .{
                            .file_index = idx,
                            .err = err,
                        } };
                        return error.CacheCheckFailed;
                    };
                }
            }
            return false;
        }

        if (self.want_shared_lock) {
            self.downgradeToSharedLock() catch |err| {
                self.diagnostic = .{ .manifest_lock = err };
                return error.CacheCheckFailed;
            };
        }

        return true;
    }

    /// Assumes that `self.hash.hasher` has been updated only with the original digest and that
    /// `self.files` contains only the original input files.
    fn hitWithCurrentLock(self: *Manifest) HitError!union(enum) {
        hit,
        miss: struct {
            file_digests_populated: usize,
        },
    } {
        const gpa = self.cache.gpa;
        const input_file_count = self.files.entries.len;
        var tiny_buffer: [1]u8 = undefined; // allows allocRemaining to detect limit exceeded
        var manifest_reader = self.manifest_file.?.reader(&tiny_buffer); // Reads positionally from zero.
        const limit: std.io.Limit = .limited(manifest_file_size_max);
        const file_contents = manifest_reader.interface.allocRemaining(gpa, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.OutOfMemory,
            error.ReadFailed => {
                self.diagnostic = .{ .manifest_read = manifest_reader.err.? };
                return error.CacheCheckFailed;
            },
        };
        defer gpa.free(file_contents);

        var any_file_changed = false;
        var line_iter = mem.tokenizeScalar(u8, file_contents, '\n');
        var idx: usize = 0;
        const header_valid = valid: {
            const line = line_iter.next() orelse break :valid false;
            break :valid std.mem.eql(u8, line, manifest_header);
        };
        if (!header_valid) {
            return .{ .miss = .{ .file_digests_populated = 0 } };
        }
        while (line_iter.next()) |line| {
            defer idx += 1;

            var iter = mem.tokenizeScalar(u8, line, ' ');
            const size = iter.next() orelse return error.InvalidFormat;
            const inode = iter.next() orelse return error.InvalidFormat;
            const mtime_nsec_str = iter.next() orelse return error.InvalidFormat;
            const digest_str = iter.next() orelse return error.InvalidFormat;
            const prefix_str = iter.next() orelse return error.InvalidFormat;
            const file_path = iter.rest();

            const stat_size = fmt.parseInt(u64, size, 10) catch return error.InvalidFormat;
            const stat_inode = fmt.parseInt(fs.File.INode, inode, 10) catch return error.InvalidFormat;
            const stat_mtime = fmt.parseInt(i64, mtime_nsec_str, 10) catch return error.InvalidFormat;
            const file_bin_digest = b: {
                if (digest_str.len != hex_digest_len) return error.InvalidFormat;
                var bd: BinDigest = undefined;
                _ = fmt.hexToBytes(&bd, digest_str) catch return error.InvalidFormat;
                break :b bd;
            };

            const prefix = fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidFormat;
            if (prefix >= self.cache.prefixes_len) return error.InvalidFormat;

            if (file_path.len == 0) return error.InvalidFormat;

            const cache_hash_file = f: {
                const prefixed_path: PrefixedPath = .{
                    .prefix = prefix,
                    .sub_path = file_path, // expires with file_contents
                };
                if (idx < input_file_count) {
                    const file = &self.files.keys()[idx];
                    if (!file.prefixed_path.eql(prefixed_path))
                        return error.InvalidFormat;

                    file.stat = .{
                        .size = stat_size,
                        .inode = stat_inode,
                        .mtime = stat_mtime,
                    };
                    file.bin_digest = file_bin_digest;
                    break :f file;
                }
                const gop = try self.files.getOrPutAdapted(gpa, prefixed_path, FilesAdapter{});
                errdefer _ = self.files.pop();
                if (!gop.found_existing) {
                    gop.key_ptr.* = .{
                        .prefixed_path = .{
                            .prefix = prefix,
                            .sub_path = try gpa.dupe(u8, file_path),
                        },
                        .contents = null,
                        .max_file_size = null,
                        .handle = null,
                        .stat = .{
                            .size = stat_size,
                            .inode = stat_inode,
                            .mtime = stat_mtime,
                        },
                        .bin_digest = file_bin_digest,
                    };
                }
                break :f gop.key_ptr;
            };

            const pp = cache_hash_file.prefixed_path;
            const dir = self.cache.prefixes()[pp.prefix].handle;
            const this_file = dir.openFile(pp.sub_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => {
                    // Every digest before this one has been populated successfully.
                    return .{ .miss = .{ .file_digests_populated = idx } };
                },
                else => |e| {
                    self.diagnostic = .{ .file_open = .{
                        .file_index = idx,
                        .err = e,
                    } };
                    return error.CacheCheckFailed;
                },
            };
            defer this_file.close();

            const actual_stat = this_file.stat() catch |err| {
                self.diagnostic = .{ .file_stat = .{
                    .file_index = idx,
                    .err = err,
                } };
                return error.CacheCheckFailed;
            };
            const size_match = actual_stat.size == cache_hash_file.stat.size;
            const mtime_match = actual_stat.mtime == cache_hash_file.stat.mtime;
            const inode_match = actual_stat.inode == cache_hash_file.stat.inode;

            if (!size_match or !mtime_match or !inode_match) {
                cache_hash_file.stat = .{
                    .size = actual_stat.size,
                    .mtime = actual_stat.mtime,
                    .inode = actual_stat.inode,
                };

                if (self.isProblematicTimestamp(cache_hash_file.stat.mtime)) {
                    // The actual file has an unreliable timestamp, force it to be hashed
                    cache_hash_file.stat.mtime = 0;
                    cache_hash_file.stat.inode = 0;
                }

                var actual_digest: BinDigest = undefined;
                hashFile(this_file, &actual_digest) catch |err| {
                    self.diagnostic = .{ .file_read = .{
                        .file_index = idx,
                        .err = err,
                    } };
                    return error.CacheCheckFailed;
                };

                if (!mem.eql(u8, &cache_hash_file.bin_digest, &actual_digest)) {
                    cache_hash_file.bin_digest = actual_digest;
                    // keep going until we have the input file digests
                    any_file_changed = true;
                }
            }

            if (!any_file_changed) {
                self.hash.hasher.update(&cache_hash_file.bin_digest);
            }
        }

        // If the manifest was somehow missing one of our input files, or if any file hash has changed,
        // then this is a cache miss. However, we have successfully populated some or all of the file
        // digests.
        if (any_file_changed or idx < input_file_count) {
            return .{ .miss = .{ .file_digests_populated = idx } };
        }

        return .hit;
    }

    /// Reset `self.hash.hasher` to the state it should be in after `hit` returns `false`.
    /// The hasher contains the original input digest, and all original input file digests (i.e.
    /// not including post files).
    /// Assumes that `bin_digest` is populated for all files up to `input_file_count`. As such,
    /// this is not necessarily safe to call within `hit`.
    pub fn unhit(self: *Manifest, bin_digest: BinDigest, input_file_count: usize) void {
        // Reset the hash.
        self.hash.hasher = hasher_init;
        self.hash.hasher.update(&bin_digest);

        // Remove files not in the initial hash.
        while (self.files.count() != input_file_count) {
            var file = self.files.pop().?;
            file.key.deinit(self.cache.gpa);
        }

        for (self.files.keys()) |file| {
            self.hash.hasher.update(&file.bin_digest);
        }
    }

    fn isProblematicTimestamp(man: *Manifest, file_time: i128) bool {
        // If the file_time is prior to the most recent problematic timestamp
        // then we don't need to access the filesystem.
        if (file_time < man.recent_problematic_timestamp)
            return false;

        // Next we will check the globally shared Cache timestamp, which is accessed
        // from multiple threads.
        man.cache.mutex.lock();
        defer man.cache.mutex.unlock();

        // Save the global one to our local one to avoid locking next time.
        man.recent_problematic_timestamp = man.cache.recent_problematic_timestamp;
        if (file_time < man.recent_problematic_timestamp)
            return false;

        // This flag prevents multiple filesystem writes for the same hit() call.
        if (man.want_refresh_timestamp) {
            man.want_refresh_timestamp = false;

            var file = man.cache.manifest_dir.createFile("timestamp", .{
                .read = true,
                .truncate = true,
            }) catch return true;
            defer file.close();

            // Save locally and also save globally (we still hold the global lock).
            man.recent_problematic_timestamp = (file.stat() catch return true).mtime;
            man.cache.recent_problematic_timestamp = man.recent_problematic_timestamp;
        }

        return file_time >= man.recent_problematic_timestamp;
    }

    fn populateFileHash(self: *Manifest, ch_file: *File) !void {
        if (ch_file.handle) |handle| {
            return populateFileHashHandle(self, ch_file, handle);
        } else {
            const pp = ch_file.prefixed_path;
            const dir = self.cache.prefixes()[pp.prefix].handle;
            const handle = try dir.openFile(pp.sub_path, .{});
            defer handle.close();
            return populateFileHashHandle(self, ch_file, handle);
        }
    }

    fn populateFileHashHandle(self: *Manifest, ch_file: *File, handle: fs.File) !void {
        const actual_stat = try handle.stat();
        ch_file.stat = .{
            .size = actual_stat.size,
            .mtime = actual_stat.mtime,
            .inode = actual_stat.inode,
        };

        if (self.isProblematicTimestamp(ch_file.stat.mtime)) {
            // The actual file has an unreliable timestamp, force it to be hashed
            ch_file.stat.mtime = 0;
            ch_file.stat.inode = 0;
        }

        if (ch_file.max_file_size) |max_file_size| {
            if (ch_file.stat.size > max_file_size) {
                return error.FileTooBig;
            }

            const contents = try self.cache.gpa.alloc(u8, @as(usize, @intCast(ch_file.stat.size)));
            errdefer self.cache.gpa.free(contents);

            // Hash while reading from disk, to keep the contents in the cpu cache while
            // doing hashing.
            var hasher = hasher_init;
            var off: usize = 0;
            while (true) {
                const bytes_read = try handle.pread(contents[off..], off);
                if (bytes_read == 0) break;
                hasher.update(contents[off..][0..bytes_read]);
                off += bytes_read;
            }
            hasher.final(&ch_file.bin_digest);

            ch_file.contents = contents;
        } else {
            try hashFile(handle, &ch_file.bin_digest);
        }

        self.hash.hasher.update(&ch_file.bin_digest);
    }

    /// Add a file as a dependency of process being cached, after the initial hash has been
    /// calculated. This is useful for processes that don't know all the files that
    /// are depended on ahead of time. For example, a source file that can import other files
    /// will need to be recompiled if the imported file is changed.
    pub fn addFilePostFetch(self: *Manifest, file_path: []const u8, max_file_size: usize) ![]const u8 {
        assert(self.manifest_file != null);

        const gpa = self.cache.gpa;
        const prefixed_path = try self.cache.findPrefix(file_path);
        errdefer gpa.free(prefixed_path.sub_path);

        const gop = try self.files.getOrPutAdapted(gpa, prefixed_path, FilesAdapter{});
        errdefer _ = self.files.pop();

        if (gop.found_existing) {
            gpa.free(prefixed_path.sub_path);
            return gop.key_ptr.contents.?;
        }

        gop.key_ptr.* = .{
            .prefixed_path = prefixed_path,
            .max_file_size = max_file_size,
            .stat = undefined,
            .bin_digest = undefined,
            .contents = null,
        };

        self.files.lockPointers();
        defer self.files.unlockPointers();

        try self.populateFileHash(gop.key_ptr);
        return gop.key_ptr.contents.?;
    }

    /// Add a file as a dependency of process being cached, after the initial hash has been
    /// calculated.
    ///
    /// This is useful for processes that don't know the all the files that are
    /// depended on ahead of time. For example, a source file that can import
    /// other files will need to be recompiled if the imported file is changed.
    pub fn addFilePost(self: *Manifest, file_path: []const u8) !void {
        assert(self.manifest_file != null);

        const gpa = self.cache.gpa;
        const prefixed_path = try self.cache.findPrefix(file_path);
        errdefer gpa.free(prefixed_path.sub_path);

        const gop = try self.files.getOrPutAdapted(gpa, prefixed_path, FilesAdapter{});
        errdefer _ = self.files.pop();

        if (gop.found_existing) {
            gpa.free(prefixed_path.sub_path);
            return;
        }

        gop.key_ptr.* = .{
            .prefixed_path = prefixed_path,
            .max_file_size = null,
            .handle = null,
            .stat = undefined,
            .bin_digest = undefined,
            .contents = null,
        };

        self.files.lockPointers();
        defer self.files.unlockPointers();

        try self.populateFileHash(gop.key_ptr);
    }

    /// Like `addFilePost` but when the file contents have already been loaded from disk.
    pub fn addFilePostContents(
        self: *Manifest,
        file_path: []const u8,
        bytes: []const u8,
        stat: File.Stat,
    ) !void {
        assert(self.manifest_file != null);
        const gpa = self.cache.gpa;

        const prefixed_path = try self.cache.findPrefix(file_path);
        errdefer gpa.free(prefixed_path.sub_path);

        const gop = try self.files.getOrPutAdapted(gpa, prefixed_path, FilesAdapter{});
        errdefer _ = self.files.pop();

        if (gop.found_existing) {
            gpa.free(prefixed_path.sub_path);
            return;
        }

        const new_file = gop.key_ptr;

        new_file.* = .{
            .prefixed_path = prefixed_path,
            .max_file_size = null,
            .handle = null,
            .stat = stat,
            .bin_digest = undefined,
            .contents = null,
        };

        if (self.isProblematicTimestamp(new_file.stat.mtime)) {
            // The actual file has an unreliable timestamp, force it to be hashed
            new_file.stat.mtime = 0;
            new_file.stat.inode = 0;
        }

        {
            var hasher = hasher_init;
            hasher.update(bytes);
            hasher.final(&new_file.bin_digest);
        }

        self.hash.hasher.update(&new_file.bin_digest);
    }

    pub fn addDepFilePost(self: *Manifest, dir: fs.Dir, dep_file_basename: []const u8) !void {
        assert(self.manifest_file != null);
        return self.addDepFileMaybePost(dir, dep_file_basename);
    }

    fn addDepFileMaybePost(self: *Manifest, dir: fs.Dir, dep_file_basename: []const u8) !void {
        const gpa = self.cache.gpa;
        const dep_file_contents = try dir.readFileAlloc(gpa, dep_file_basename, manifest_file_size_max);
        defer gpa.free(dep_file_contents);

        var error_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer error_buf.deinit(gpa);

        var resolve_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer resolve_buf.deinit(gpa);

        var it: DepTokenizer = .{ .bytes = dep_file_contents };
        while (it.next()) |token| {
            switch (token) {
                // We don't care about targets, we only want the prereqs
                // Clang is invoked in single-source mode but other programs may not
                .target, .target_must_resolve => {},
                .prereq => |file_path| if (self.manifest_file == null) {
                    _ = try self.addFile(file_path, null);
                } else try self.addFilePost(file_path),
                .prereq_must_resolve => {
                    resolve_buf.clearRetainingCapacity();
                    try token.resolve(gpa, &resolve_buf);
                    if (self.manifest_file == null) {
                        _ = try self.addFile(resolve_buf.items, null);
                    } else try self.addFilePost(resolve_buf.items);
                },
                else => |err| {
                    try err.printError(gpa, &error_buf);
                    log.err("failed parsing {s}: {s}", .{ dep_file_basename, error_buf.items });
                    return error.InvalidDepFile;
                },
            }
        }
    }

    /// Returns a binary hash of the inputs.
    pub fn finalBin(self: *Manifest) BinDigest {
        assert(self.manifest_file != null);

        // We don't close the manifest file yet, because we want to
        // keep it locked until the API user is done using it.
        // We also don't write out the manifest yet, because until
        // cache_release is called we still might be working on creating
        // the artifacts to cache.

        var bin_digest: BinDigest = undefined;
        self.hash.hasher.final(&bin_digest);
        return bin_digest;
    }

    /// Returns a hex encoded hash of the inputs.
    pub fn final(self: *Manifest) HexDigest {
        const bin_digest = self.finalBin();
        return binToHex(bin_digest);
    }

    /// If `want_shared_lock` is true, this function automatically downgrades the
    /// lock from exclusive to shared.
    pub fn writeManifest(self: *Manifest) !void {
        assert(self.have_exclusive_lock);

        const manifest_file = self.manifest_file.?;
        if (self.manifest_dirty) {
            self.manifest_dirty = false;

            var buffer: [4000]u8 = undefined;
            var fw = manifest_file.writer(&buffer);
            writeDirtyManifestToStream(self, &fw) catch |err| switch (err) {
                error.WriteFailed => return fw.err.?,
                else => |e| return e,
            };
        }

        if (self.want_shared_lock) {
            try self.downgradeToSharedLock();
        }
    }

    fn writeDirtyManifestToStream(self: *Manifest, fw: *fs.File.Writer) !void {
        try fw.interface.writeAll(manifest_header ++ "\n");
        for (self.files.keys()) |file| {
            try fw.interface.print("{d} {d} {d} {x} {d} {s}\n", .{
                file.stat.size,
                file.stat.inode,
                file.stat.mtime,
                &file.bin_digest,
                file.prefixed_path.prefix,
                file.prefixed_path.sub_path,
            });
        }
        try fw.end();
    }

    fn downgradeToSharedLock(self: *Manifest) !void {
        if (!self.have_exclusive_lock) return;

        // WASI does not currently support flock, so we bypass it here.
        // TODO: If/when flock is supported on WASI, this check should be removed.
        //       See https://github.com/WebAssembly/wasi-filesystem/issues/2
        if (builtin.os.tag != .wasi or std.process.can_spawn or !builtin.single_threaded) {
            const manifest_file = self.manifest_file.?;
            try manifest_file.downgradeLock();
        }

        self.have_exclusive_lock = false;
    }

    fn upgradeToExclusiveLock(self: *Manifest) error{CacheCheckFailed}!bool {
        if (self.have_exclusive_lock) return false;
        assert(self.manifest_file != null);

        // WASI does not currently support flock, so we bypass it here.
        // TODO: If/when flock is supported on WASI, this check should be removed.
        //       See https://github.com/WebAssembly/wasi-filesystem/issues/2
        if (builtin.os.tag != .wasi or std.process.can_spawn or !builtin.single_threaded) {
            const manifest_file = self.manifest_file.?;
            // Here we intentionally have a period where the lock is released, in case there are
            // other processes holding a shared lock.
            manifest_file.unlock();
            manifest_file.lock(.exclusive) catch |err| {
                self.diagnostic = .{ .manifest_lock = err };
                return error.CacheCheckFailed;
            };
        }
        self.have_exclusive_lock = true;
        return true;
    }

    /// Obtain only the data needed to maintain a lock on the manifest file.
    /// The `Manifest` remains safe to deinit.
    /// Don't forget to call `writeManifest` before this!
    pub fn toOwnedLock(self: *Manifest) Lock {
        const lock: Lock = .{
            .manifest_file = self.manifest_file.?,
        };

        self.manifest_file = null;
        return lock;
    }

    /// Releases the manifest file and frees any memory the Manifest was using.
    /// `Manifest.hit` must be called first.
    /// Don't forget to call `writeManifest` before this!
    pub fn deinit(self: *Manifest) void {
        if (self.manifest_file) |file| {
            if (builtin.os.tag == .windows) {
                // See Lock.release for why this is required on Windows
                file.unlock();
            }

            file.close();
        }
        for (self.files.keys()) |*file| {
            file.deinit(self.cache.gpa);
        }
        self.files.deinit(self.cache.gpa);
    }

    pub fn populateFileSystemInputs(man: *Manifest, buf: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
        assert(@typeInfo(std.zig.Server.Message.PathPrefix).@"enum".fields.len == man.cache.prefixes_len);
        buf.clearRetainingCapacity();
        const gpa = man.cache.gpa;
        const files = man.files.keys();
        if (files.len > 0) {
            for (files) |file| {
                try buf.ensureUnusedCapacity(gpa, file.prefixed_path.sub_path.len + 2);
                buf.appendAssumeCapacity(file.prefixed_path.prefix + 1);
                buf.appendSliceAssumeCapacity(file.prefixed_path.sub_path);
                buf.appendAssumeCapacity(0);
            }
            // The null byte is a separator, not a terminator.
            buf.items.len -= 1;
        }
    }

    pub fn populateOtherManifest(man: *Manifest, other: *Manifest, prefix_map: [4]u8) Allocator.Error!void {
        const gpa = other.cache.gpa;
        assert(@typeInfo(std.zig.Server.Message.PathPrefix).@"enum".fields.len == man.cache.prefixes_len);
        assert(man.cache.prefixes_len == 4);
        for (man.files.keys()) |file| {
            const prefixed_path: PrefixedPath = .{
                .prefix = prefix_map[file.prefixed_path.prefix],
                .sub_path = try gpa.dupe(u8, file.prefixed_path.sub_path),
            };
            errdefer gpa.free(prefixed_path.sub_path);

            const gop = try other.files.getOrPutAdapted(gpa, prefixed_path, FilesAdapter{});
            errdefer _ = other.files.pop();

            if (gop.found_existing) {
                gpa.free(prefixed_path.sub_path);
                continue;
            }

            gop.key_ptr.* = .{
                .prefixed_path = prefixed_path,
                .max_file_size = file.max_file_size,
                .handle = file.handle,
                .stat = file.stat,
                .bin_digest = file.bin_digest,
                .contents = null,
            };

            other.hash.hasher.update(&gop.key_ptr.bin_digest);
        }
    }
};

/// On operating systems that support symlinks, does a readlink. On other operating systems,
/// uses the file contents. Windows supports symlinks but only with elevated privileges, so
/// it is treated as not supporting symlinks.
pub fn readSmallFile(dir: fs.Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        return dir.readFile(sub_path, buffer);
    } else {
        return dir.readLink(sub_path, buffer);
    }
}

/// On operating systems that support symlinks, does a symlink. On other operating systems,
/// uses the file contents. Windows supports symlinks but only with elevated privileges, so
/// it is treated as not supporting symlinks.
/// `data` must be a valid UTF-8 encoded file path and 255 bytes or fewer.
pub fn writeSmallFile(dir: fs.Dir, sub_path: []const u8, data: []const u8) !void {
    assert(data.len <= 255);
    if (builtin.os.tag == .windows) {
        return dir.writeFile(.{ .sub_path = sub_path, .data = data });
    } else {
        return dir.symLink(data, sub_path, .{});
    }
}

fn hashFile(file: fs.File, bin_digest: *[Hasher.mac_length]u8) fs.File.PReadError!void {
    var buf: [1024]u8 = undefined;
    var hasher = hasher_init;
    var off: u64 = 0;
    while (true) {
        const bytes_read = try file.pread(&buf, off);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
        off += bytes_read;
    }
    hasher.final(bin_digest);
}

// Create/Write a file, close it, then grab its stat.mtime timestamp.
fn testGetCurrentFileTimestamp(dir: fs.Dir) !i128 {
    const test_out_file = "test-filetimestamp.tmp";

    var file = try dir.createFile(test_out_file, .{
        .read = true,
        .truncate = true,
    });
    defer {
        file.close();
        dir.deleteFile(test_out_file) catch {};
    }

    return (try file.stat()).mtime;
}

test "cache file and then recall it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_file = "test.txt";
    const temp_manifest_dir = "temp_manifest_dir";

    try tmp.dir.writeFile(.{ .sub_path = temp_file, .data = "Hello, world!\n" });

    // Wait for file timestamps to tick
    const initial_time = try testGetCurrentFileTimestamp(tmp.dir);
    while ((try testGetCurrentFileTimestamp(tmp.dir)) == initial_time) {
        std.Thread.sleep(1);
    }

    var digest1: HexDigest = undefined;
    var digest2: HexDigest = undefined;

    {
        var cache = Cache{
            .gpa = testing.allocator,
            .manifest_dir = try tmp.dir.makeOpenPath(temp_manifest_dir, .{}),
        };
        cache.addPrefix(.{ .path = null, .handle = tmp.dir });
        defer cache.manifest_dir.close();

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.add(true);
            ch.hash.add(@as(u16, 1234));
            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file, null);

            // There should be nothing in the cache
            try testing.expectEqual(false, try ch.hit());

            digest1 = ch.final();
            try ch.writeManifest();
        }
        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.add(true);
            ch.hash.add(@as(u16, 1234));
            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file, null);

            // Cache hit! We just "built" the same file
            try testing.expect(try ch.hit());
            digest2 = ch.final();

            try testing.expectEqual(false, ch.have_exclusive_lock);
        }

        try testing.expectEqual(digest1, digest2);
    }
}

test "check that changing a file makes cache fail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_file = "cache_hash_change_file_test.txt";
    const temp_manifest_dir = "cache_hash_change_file_manifest_dir";
    const original_temp_file_contents = "Hello, world!\n";
    const updated_temp_file_contents = "Hello, world; but updated!\n";

    try tmp.dir.writeFile(.{ .sub_path = temp_file, .data = original_temp_file_contents });

    // Wait for file timestamps to tick
    const initial_time = try testGetCurrentFileTimestamp(tmp.dir);
    while ((try testGetCurrentFileTimestamp(tmp.dir)) == initial_time) {
        std.Thread.sleep(1);
    }

    var digest1: HexDigest = undefined;
    var digest2: HexDigest = undefined;

    {
        var cache = Cache{
            .gpa = testing.allocator,
            .manifest_dir = try tmp.dir.makeOpenPath(temp_manifest_dir, .{}),
        };
        cache.addPrefix(.{ .path = null, .handle = tmp.dir });
        defer cache.manifest_dir.close();

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            const temp_file_idx = try ch.addFile(temp_file, 100);

            // There should be nothing in the cache
            try testing.expectEqual(false, try ch.hit());

            try testing.expect(mem.eql(u8, original_temp_file_contents, ch.files.keys()[temp_file_idx].contents.?));

            digest1 = ch.final();

            try ch.writeManifest();
        }

        try tmp.dir.writeFile(.{ .sub_path = temp_file, .data = updated_temp_file_contents });

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            const temp_file_idx = try ch.addFile(temp_file, 100);

            // A file that we depend on has been updated, so the cache should not contain an entry for it
            try testing.expectEqual(false, try ch.hit());

            // The cache system does not keep the contents of re-hashed input files.
            try testing.expect(ch.files.keys()[temp_file_idx].contents == null);

            digest2 = ch.final();

            try ch.writeManifest();
        }

        try testing.expect(!mem.eql(u8, digest1[0..], digest2[0..]));
    }
}

test "no file inputs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_manifest_dir = "no_file_inputs_manifest_dir";

    var digest1: HexDigest = undefined;
    var digest2: HexDigest = undefined;

    var cache = Cache{
        .gpa = testing.allocator,
        .manifest_dir = try tmp.dir.makeOpenPath(temp_manifest_dir, .{}),
    };
    cache.addPrefix(.{ .path = null, .handle = tmp.dir });
    defer cache.manifest_dir.close();

    {
        var man = cache.obtain();
        defer man.deinit();

        man.hash.addBytes("1234");

        // There should be nothing in the cache
        try testing.expectEqual(false, try man.hit());

        digest1 = man.final();

        try man.writeManifest();
    }
    {
        var man = cache.obtain();
        defer man.deinit();

        man.hash.addBytes("1234");

        try testing.expect(try man.hit());
        digest2 = man.final();
        try testing.expectEqual(false, man.have_exclusive_lock);
    }

    try testing.expectEqual(digest1, digest2);
}

test "Manifest with files added after initial hash work" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_file1 = "cache_hash_post_file_test1.txt";
    const temp_file2 = "cache_hash_post_file_test2.txt";
    const temp_manifest_dir = "cache_hash_post_file_manifest_dir";

    try tmp.dir.writeFile(.{ .sub_path = temp_file1, .data = "Hello, world!\n" });
    try tmp.dir.writeFile(.{ .sub_path = temp_file2, .data = "Hello world the second!\n" });

    // Wait for file timestamps to tick
    const initial_time = try testGetCurrentFileTimestamp(tmp.dir);
    while ((try testGetCurrentFileTimestamp(tmp.dir)) == initial_time) {
        std.Thread.sleep(1);
    }

    var digest1: HexDigest = undefined;
    var digest2: HexDigest = undefined;
    var digest3: HexDigest = undefined;

    {
        var cache = Cache{
            .gpa = testing.allocator,
            .manifest_dir = try tmp.dir.makeOpenPath(temp_manifest_dir, .{}),
        };
        cache.addPrefix(.{ .path = null, .handle = tmp.dir });
        defer cache.manifest_dir.close();

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file1, null);

            // There should be nothing in the cache
            try testing.expectEqual(false, try ch.hit());

            _ = try ch.addFilePost(temp_file2);

            digest1 = ch.final();
            try ch.writeManifest();
        }
        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file1, null);

            try testing.expect(try ch.hit());
            digest2 = ch.final();

            try testing.expectEqual(false, ch.have_exclusive_lock);
        }
        try testing.expect(mem.eql(u8, &digest1, &digest2));

        // Modify the file added after initial hash
        try tmp.dir.writeFile(.{ .sub_path = temp_file2, .data = "Hello world the second, updated\n" });

        // Wait for file timestamps to tick
        const initial_time2 = try testGetCurrentFileTimestamp(tmp.dir);
        while ((try testGetCurrentFileTimestamp(tmp.dir)) == initial_time2) {
            std.Thread.sleep(1);
        }

        {
            var ch = cache.obtain();
            defer ch.deinit();

            ch.hash.addBytes("1234");
            _ = try ch.addFile(temp_file1, null);

            // A file that we depend on has been updated, so the cache should not contain an entry for it
            try testing.expectEqual(false, try ch.hit());

            _ = try ch.addFilePost(temp_file2);

            digest3 = ch.final();

            try ch.writeManifest();
        }

        try testing.expect(!mem.eql(u8, &digest1, &digest3));
    }
}
