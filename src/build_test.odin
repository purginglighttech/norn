// Tests for the build module: build.conf parsing, layered toolchain
// resolution, and script execution.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "norn:manifest"

build_work_dir :: proc(t: ^testing.T, tag: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir, _ := filepath.join([]string{base, fmt.tprintf("norn-build-%s-%d", tag, os.get_pid())})
    defer delete(dir)
    if merr := os.make_directory(dir); merr != nil {
        testing.fail_now(t)
    }
    return strings.clone(dir)
}

write_build_conf :: proc(t: ^testing.T, path: string) {
    content := `[toolchain]
cc = "clang"
cxx = "clang++"
cflags = "-O2"
cxxflags = "-O2"
ldflags = "-Wl,-O1"

[build]
jobs = 4
strip = true
debug = false
builddir = "/var/tmp/norn-build"
`
    if werr := os.write_entire_file(path, content); werr != nil {
        testing.fail_now(t)
    }
}

@(test)
test_load_build_conf :: proc(t: ^testing.T) {
    work := build_work_dir(t, "conf")
    defer delete(work)
    defer os.remove_all(work)
    cfg, _ := filepath.join([]string{work, "build.conf"})
    defer delete(cfg)
    write_build_conf(t, cfg)

    p, err := load_build_conf(cfg)
    defer free_build_profile(&p)
    testing.expect(t, err == "", "valid build.conf should parse")
    if err != "" {
        return
    }
    testing.expect(t, p.cc == "clang", "cc")
    testing.expect(t, p.cxx == "clang++", "cxx")
    testing.expect(t, p.cflags == "-O2", "cflags")
    testing.expect(t, p.jobs == 4, "jobs")
    testing.expect(t, p.strip == true, "strip")
    testing.expect(t, p.debug == false, "debug")
    testing.expect(t, p.builddir == "/var/tmp/norn-build", "builddir")
}

@(test)
test_load_build_conf_missing_key :: proc(t: ^testing.T) {
    work := build_work_dir(t, "conf-bad")
    defer delete(work)
    defer os.remove_all(work)
    cfg, _ := filepath.join([]string{work, "build.conf"})
    defer delete(cfg)
    // Missing toolchain.cxx.
    content := `[toolchain]
cc = "clang"
cflags = "-O2"
cxxflags = "-O2"
ldflags = "-Wl,-O1"

[build]
jobs = 4
strip = true
debug = false
builddir = "/var/tmp/norn-build"
`
    if werr := os.write_entire_file(cfg, content); werr != nil {
        testing.fail_now(t)
    }
    p, err := load_build_conf(cfg)
    defer free_build_profile(&p)
    testing.expect(t, err != "", "missing key should fail")
    testing.expect(t, strings.contains(err, "toolchain.cxx"), "error should name the key")
}

@(test)
test_resolve_toolchain :: proc(t: ^testing.T) {
    base := Build_Profile{
        cc       = strings.clone("clang"),
        cxx      = strings.clone("clang++"),
        cflags   = strings.clone("-O2"),
        cxxflags = strings.clone("-O2"),
        ldflags  = strings.clone("-Wl,-O1"),
        jobs     = 4,
        strip    = true,
        debug    = false,
        builddir = strings.clone("/var/tmp/norn-build"),
    }
    defer free_build_profile(&base)

    // Manifest overrides cc and cflags; appends to cflags.
    m: manifest.Manifest
    m.build.cc = strings.clone("gcc")
    m.build.cflags = strings.clone("-O1")
    append_arr := make([dynamic]string)
    append(&append_arr, strings.clone("-fno-strict-aliasing"))
    m.build.cflags_append = append_arr[:]
    defer manifest.manifest_destroy(&m)

    out := resolve_toolchain(&base, &m, nil)
    defer free_build_profile(&out)
    testing.expect(t, out.cc == "gcc", "manifest cc replaces")
    testing.expect(t, out.cxx == "clang++", "unset cxx comes from build.conf")
    testing.expect(t, out.cflags == "-O1 -fno-strict-aliasing", "replace then append")
    testing.expect(t, out.cxxflags == "-O2", "unset cxxflags from build.conf")
    testing.expect(t, out.jobs == 4, "jobs is build.conf-only")
}

@(test)
test_run_build_script :: proc(t: ^testing.T) {
    work := build_work_dir(t, "run")
    defer delete(work)
    defer os.remove_all(work)

    srcdir, _ := filepath.join([]string{work, "src"})
    defer delete(srcdir)
    if merr := os.make_directory(srcdir); merr != nil {
        testing.fail_now(t)
    }

    // A script that writes $PREFIX, $CC, and cwd into files.
    m: manifest.Manifest
    m.pkg.name = strings.clone("foo")
    m.pkg.version = strings.clone("1.0")
    m.build.script = strings.clone("echo \"$PREFIX\" > prefix.txt; echo \"$CC\" > cc.txt; pwd > cwd.txt")
    // Source tier present so the script isn't skipped.
    m.tarball.present = true
    defer manifest.manifest_destroy(&m)

    prof := Build_Profile{
        cc       = strings.clone("mycc"),
        cxx      = strings.clone("mycxx"),
        cflags   = strings.clone("-O2"),
        cxxflags = strings.clone("-O2"),
        ldflags  = strings.clone(""),
        jobs     = 2,
        builddir = strings.clone(work),
    }
    defer free_build_profile(&prof)

    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)
    opts := Build_Opts{sysroot = sysroot, shell_bin = "/bin/sh"}

    err := run_build(&m, srcdir, &prof, &opts)
    testing.expectf(t, err == "", "build should succeed, got: %s", err)
    if err != "" {
        return
    }
    // $PREFIX should be under the sysroot.
    prefix_file, _ := filepath.join([]string{srcdir, "prefix.txt"})
    defer delete(prefix_file)
    data, rerr := os.read_entire_file(prefix_file, context.allocator)
    defer delete(data)
    testing.expect(t, rerr == nil, "prefix.txt should exist")
    if rerr == nil {
        want := fmt.tprintf("%s/usr/apps/foo/1.0", sysroot)
        testing.expect(t, strings.trim_space(string(data)) == want, "$PREFIX under sysroot")
    }
    // $CC should be the profile's cc.
    cc_file, _ := filepath.join([]string{srcdir, "cc.txt"})
    defer delete(cc_file)
    cc_data, cerr := os.read_entire_file(cc_file, context.allocator)
    defer delete(cc_data)
    testing.expect(t, cerr == nil, "cc.txt should exist")
    if cerr == nil {
        testing.expect(t, strings.trim_space(string(cc_data)) == "mycc", "$CC from profile")
    }
}

@(test)
test_run_build_no_script :: proc(t: ^testing.T) {
    work := build_work_dir(t, "no-script")
    defer delete(work)
    defer os.remove_all(work)

    m: manifest.Manifest
    m.pkg.name = strings.clone("foo")
    m.pkg.version = strings.clone("1.0")
    m.tarball.present = true
    // No script.
    defer manifest.manifest_destroy(&m)

    prof := Build_Profile{jobs = 1, builddir = strings.clone(work)}
    defer free_build_profile(&prof)
    opts := Build_Opts{sysroot = "/", shell_bin = "/bin/sh"}

    err := run_build(&m, work, &prof, &opts)
    testing.expect(t, err != "", "source tier without script should fail")
    testing.expect(t, strings.contains(err, "script"), "error should mention script")
}
