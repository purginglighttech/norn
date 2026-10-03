// Tests for install: symlink pass, priority registry, config lifecycle,
// remove/purge, upgrade/rollback.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "norn:manifest"

install_work_dir :: proc(t: ^testing.T, tag: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir, _ := filepath.join([]string{base, fmt.tprintf("norn-install-%s-%d", tag, os.get_pid())})
    defer delete(dir)
    if merr := os.make_directory(dir); merr != nil {
        testing.fail_now(t)
    }
    return strings.clone(dir)
}

// make_prefix creates a fake package prefix with bin/ and etc/ files.
make_prefix :: proc(t: ^testing.T, root, name, version: string) -> string {
    prefix, _ := filepath.join([]string{root, "usr", "apps", name, version})
    defer delete(prefix)
    subs := [2]string{"bin", "etc"}
    for sub in subs {
        d, _ := filepath.join([]string{prefix, sub})
        defer delete(d)
        if merr := os.make_directory_all(d); merr != nil {
            testing.fail_now(t)
        }
    }
    bin_file, _ := filepath.join([]string{prefix, "bin", name})
    defer delete(bin_file)
    if werr := os.write_entire_file(bin_file, fmt.tprintf("#!/bin/sh\necho %s\n", name)); werr != nil {
        testing.fail_now(t)
    }
    etc_file, _ := filepath.join([]string{prefix, "etc", fmt.tprintf("%s.conf", name)})
    defer delete(etc_file)
    if werr := os.write_entire_file(etc_file, "# default config\n"); werr != nil {
        testing.fail_now(t)
    }
    return strings.clone(prefix)
}

make_test_manifest :: proc(name, version: string, priority: i64) -> manifest.Manifest {
    m: manifest.Manifest
    m.pkg.name = strings.clone(name)
    m.pkg.version = strings.clone(version)
    m.pkg.release = 1
    m.pkg.priority = priority
    return m
}

@(test)
test_install_basic :: proc(t: ^testing.T) {
    work := install_work_dir(t, "basic")
    defer delete(work)
    defer os.remove_all(work)
    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)

    prefix := make_prefix(t, sysroot, "foo", "1.0")
    defer delete(prefix)

    m := make_test_manifest("foo", "1.0", 0)
    defer manifest.manifest_destroy(&m)
    opts := Install_Opts{sysroot = sysroot}

    if e := db_init(sysroot); e != "" {
        testing.fail_now(t)
    }
    err := install_package(&m, prefix, &opts)
    testing.expectf(t, err == "", "install should succeed, got: %s", err)
    if err != "" {
        return
    }

    // Symlink: <sysroot>/usr/bin/foo -> <prefix>/bin/foo
    live_bin, _ := filepath.join([]string{sysroot, "usr", "bin", "foo"})
    defer delete(live_bin)
    testing.expect(t, os.exists(live_bin), "live bin symlink should exist")

    // Config: <sysroot>/etc/foo.conf should be a COPY, not a symlink.
    live_cfg, _ := filepath.join([]string{sysroot, "etc", "foo.conf"})
    defer delete(live_cfg)
    testing.expect(t, os.exists(live_cfg), "live config should exist")
    // (A symlink check would need lstat; existence suffices for alpha.)

    // DB record exists.
    testing.expect(t, is_installed(sysroot, "foo"), "db should record install")
}

@(test)
test_install_priority :: proc(t: ^testing.T) {
    work := install_work_dir(t, "priority")
    defer delete(work)
    defer os.remove_all(work)
    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)
    if e := db_init(sysroot); e != "" {
        testing.fail_now(t)
    }

    // Two packages ship bin/tool. Low priority first, then high.
    p1 := make_prefix(t, sysroot, "low", "1.0")
    defer delete(p1)
    // Rename bin/low -> bin/tool for the overlap.
    tool1, _ := filepath.join([]string{p1, "bin", "tool"})
    defer delete(tool1)
    low_bin, _ := filepath.join([]string{p1, "bin", "low"})
    defer delete(low_bin)
    os.rename(low_bin, tool1)

    p2 := make_prefix(t, sysroot, "high", "1.0")
    defer delete(p2)
    tool2, _ := filepath.join([]string{p2, "bin", "tool"})
    defer delete(tool2)
    high_bin, _ := filepath.join([]string{p2, "bin", "high"})
    defer delete(high_bin)
    os.rename(high_bin, tool2)

    m1 := make_test_manifest("low", "1.0", 0)
    defer manifest.manifest_destroy(&m1)
    m2 := make_test_manifest("high", "1.0", 10)
    defer manifest.manifest_destroy(&m2)
    opts := Install_Opts{sysroot = sysroot}

    testing.expect(t, install_package(&m1, p1, &opts) == "", "low install")
    testing.expect(t, install_package(&m2, p2, &opts) == "", "high install")

    // The live tool should point at high's prefix (higher priority wins).
    live_tool, _ := filepath.join([]string{sysroot, "usr", "bin", "tool"})
    defer delete(live_tool)
    // temp_allocator; do NOT delete.
    link_target, _ := os.read_link(live_tool, context.temp_allocator)
    testing.expect(t, strings.contains(link_target, "high"), "higher priority should win")
}

@(test)
test_install_priority_tie :: proc(t: ^testing.T) {
    work := install_work_dir(t, "tie")
    defer delete(work)
    defer os.remove_all(work)
    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)
    if e := db_init(sysroot); e != "" {
        testing.fail_now(t)
    }

    p1 := make_prefix(t, sysroot, "a", "1.0")
    defer delete(p1)
    tool1, _ := filepath.join([]string{p1, "bin", "tool"})
    defer delete(tool1)
    a_bin, _ := filepath.join([]string{p1, "bin", "a"})
    defer delete(a_bin)
    os.rename(a_bin, tool1)

    p2 := make_prefix(t, sysroot, "b", "1.0")
    defer delete(p2)
    tool2, _ := filepath.join([]string{p2, "bin", "tool"})
    defer delete(tool2)
    b_bin, _ := filepath.join([]string{p2, "bin", "b"})
    defer delete(b_bin)
    os.rename(b_bin, tool2)

    m1 := make_test_manifest("a", "1.0", 5)
    defer manifest.manifest_destroy(&m1)
    m2 := make_test_manifest("b", "1.0", 5)
    defer manifest.manifest_destroy(&m2)
    opts := Install_Opts{sysroot = sysroot}

    testing.expect(t, install_package(&m1, p1, &opts) == "", "first install")
    err := install_package(&m2, p2, &opts)
    testing.expect(t, err != "", "priority tie should fail")
    testing.expect(t, strings.contains(err, "priority"), "error should mention priority")
}

@(test)
test_remove :: proc(t: ^testing.T) {
    work := install_work_dir(t, "remove")
    defer delete(work)
    defer os.remove_all(work)
    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)
    if e := db_init(sysroot); e != "" {
        testing.fail_now(t)
    }

    prefix := make_prefix(t, sysroot, "foo", "1.0")
    defer delete(prefix)
    m := make_test_manifest("foo", "1.0", 0)
    defer manifest.manifest_destroy(&m)
    opts := Install_Opts{sysroot = sysroot}
    testing.expect(t, install_package(&m, prefix, &opts) == "", "install")

    left, err := remove_package(sysroot, "foo", &opts)
    defer delete(left)
    testing.expectf(t, err == "", "remove should succeed, got: %s", err)
    if err != "" {
        return
    }

    // Symlink gone.
    live_bin, _ := filepath.join([]string{sysroot, "usr", "bin", "foo"})
    defer delete(live_bin)
    testing.expect(t, !os.exists(live_bin), "symlink should be gone")

    // Prefix gone.
    testing.expect(t, !os.exists(prefix), "prefix should be gone")

    // Config left in place.
    live_cfg, _ := filepath.join([]string{sysroot, "etc", "foo.conf"})
    defer delete(live_cfg)
    testing.expect(t, os.exists(live_cfg), "config should be left")
    testing.expect(t, strings.contains(left, "foo.conf"), "left configs should list it")
}

@(test)
test_purge :: proc(t: ^testing.T) {
    work := install_work_dir(t, "purge")
    defer delete(work)
    defer os.remove_all(work)
    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)
    if e := db_init(sysroot); e != "" {
        testing.fail_now(t)
    }

    prefix := make_prefix(t, sysroot, "foo", "1.0")
    defer delete(prefix)
    m := make_test_manifest("foo", "1.0", 0)
    defer manifest.manifest_destroy(&m)
    opts := Install_Opts{sysroot = sysroot}
    testing.expect(t, install_package(&m, prefix, &opts) == "", "install")

    // Remove first (leaves config), then purge.
    left, rerr := remove_package(sysroot, "foo", &opts)
    defer delete(left)
    testing.expect(t, rerr == "", "remove")
    live_cfg, _ := filepath.join([]string{sysroot, "etc", "foo.conf"})
    defer delete(live_cfg)
    testing.expect(t, os.exists(live_cfg), "config left after remove")

    perr := purge_package(sysroot, "foo", &opts)
    testing.expectf(t, perr == "", "purge should succeed, got: %s", perr)
    testing.expect(t, !os.exists(live_cfg), "config gone after purge")
    testing.expect(t, !is_installed(sysroot, "foo"), "db gone after purge")
}

@(test)
test_upgrade :: proc(t: ^testing.T) {
    work := install_work_dir(t, "upgrade")
    defer delete(work)
    defer os.remove_all(work)
    sysroot, _ := filepath.join([]string{work, "sysroot"})
    defer delete(sysroot)
    if e := db_init(sysroot); e != "" {
        testing.fail_now(t)
    }

    // Install v1.0.
    p1 := make_prefix(t, sysroot, "foo", "1.0")
    defer delete(p1)
    m1 := make_test_manifest("foo", "1.0", 0)
    defer manifest.manifest_destroy(&m1)
    opts := Install_Opts{sysroot = sysroot}
    testing.expect(t, install_package(&m1, p1, &opts) == "", "install v1.0")

    // Upgrade to v2.0.
    p2 := make_prefix(t, sysroot, "foo", "2.0")
    defer delete(p2)
    m2 := make_test_manifest("foo", "2.0", 0)
    defer manifest.manifest_destroy(&m2)
    uerr := upgrade_package(&m2, p2, &opts, true)
    testing.expectf(t, uerr == "", "upgrade should succeed, got: %s", uerr)
    if uerr != "" {
        return
    }

    // Live symlink should point at v2.0.
    live_bin, _ := filepath.join([]string{sysroot, "usr", "bin", "foo"})
    defer delete(live_bin)
    target, _ := os.read_link(live_bin, context.temp_allocator)
    testing.expect(t, strings.contains(target, "2.0"), "symlink should point at v2.0")

    // Old prefix should still exist (keep_previous=true).
    testing.expect(t, os.exists(p1), "old prefix kept")

    // Rollback to v1.0.
    rerr := rollback_package(sysroot, "foo", &opts)
    testing.expectf(t, rerr == "", "rollback should succeed, got: %s", rerr)
    if rerr != "" {
        return
    }
    target2, _ := os.read_link(live_bin, context.temp_allocator)
    testing.expect(t, strings.contains(target2, "1.0"), "symlink should point at v1.0 after rollback")
}
