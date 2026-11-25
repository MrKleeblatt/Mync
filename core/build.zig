const std = @import("std");

pub fn build(b: *std.Build) void {
    // Ohne -Dtarget nicht für den Prozessor des Build-Rechners bauen
    // (native): Der Release-Runner hat AVX2/BMI2/SHA-NI, ältere Rechner nicht
    // und stürzten mit SIGILL ab.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_flags = [_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
    };

    // Kernmodul (Zig) inkl. SQLite (C)
    const core = b.addModule("mync_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &sqlite_flags });
    core.addIncludePath(b.path("vendor/sqlite"));

    const opts = b.addOptions();
    opts.addOption([]const u8, "testdata_dir", b.root.joinString(b.allocator, "testdata") catch @panic("OOM"));
    core.addOptions("build_options", opts);

    // Gemeinsame Bibliothek für die Flutter-App (C-ABI, siehe src/ffi.zig)
    const lib = b.addLibrary(.{
        .name = "mync_core",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = if (optimize == .debug) null else true,
            .imports = &.{.{ .name = "mync_core", .module = core }},
        }),
    });
    // Android: Zig bringt keine Bionic-libc mit – sie kommt aus dem NDK.
    //   zig build -Dtarget=aarch64-linux-android -Dandroid-ndk=$ANDROID_NDK_HOME
    const is_android = target.result.abi.isAndroid();
    if (is_android) {
        const ndk = b.option([]const u8, "android-ndk", "Pfad zum Android-NDK (für Android-Ziele nötig)") orelse
            @panic("Für Android-Ziele -Dandroid-ndk=<Pfad zum NDK> angeben");
        lib.setLibCFile(androidLibcFile(b, ndk, target.result));
        lib.link_z_max_page_size = 16384; // Android 15+: 16-KB-Seiten
    }
    b.installArtifact(lib);
    if (is_android) return; // CLI und Tests nur für Desktop-Ziele

    // Kommandozeilenwerkzeug
    const exe = b.addExecutable(.{
        .name = "mync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mync_core", .module = core }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    b.step("run", "CLI ausführen: zig build run -- scan ~/Musik").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = core });
    const ffi_tests = b.addTest(.{ .root_module = lib.root_module });
    const test_step = b.step("test", "Tests ausführen");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(ffi_tests).step);
}

/// Erzeugt die libc-Beschreibung für ein Android-Ziel aus dem NDK.
fn androidLibcFile(b: *std.Build, ndk: []const u8, t: std.Target) std.Build.LazyPath {
    const host = switch (@import("builtin").os.tag) {
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
    const triple = switch (t.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        else => @panic("nicht unterstützte Android-Architektur"),
    };
    const api = t.os.version_range.linux.android;
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk, host });
    const content = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/{s}
        \\crt_dir={s}/usr/lib/{s}/{d}
        \\cc_dir={s}/usr/lib/{s}/{d}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\darwin_sdk_dir=
        \\
    , .{ sysroot, sysroot, triple, sysroot, triple, api, sysroot, triple, api });
    return b.addWriteFiles().add("android-libc.txt", content);
}
