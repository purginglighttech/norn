// Tests for dependency resolution: linear chains, diamonds, cycles,
// missing deps, and the core-containment rule.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// deps_work_dir creates a fake ports tree: <base>/core/<cat>/ and
// <base>/extra/<cat>/.
deps_work_dir :: proc(t: ^testing.T, tag: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir, _ := filepath.join([]string{base, fmt.tprintf("norn-deps-%s-%d", tag, os.get_pid())})
    defer delete(dir)
    repos := []string{"core", "extra"}
    for repo in repos {
        sub, _ := filepath.join([]string{dir, repo, "sys"})
        defer delete(sub)
        if merr := os.make_directory_all(sub); merr != nil {
            testing.fail_now(t)
        }
    }
    return strings.clone(dir)
}

// write_pkgsrc writes a minimal manifest with the given deps.
write_pkgsrc :: proc(t: ^testing.T, ports_root, repo, name: string, build_deps, run_deps: []string) {
    path, _ := filepath.join([]string{ports_root, repo, "sys", fmt.tprintf("%s.pkgsrc", name)})
    defer delete(path)
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "[package]\n")
    strings.write_string(&sb, fmt.tprintf("name = \"%s\"\nversion = \"1.0\"\nrelease = 1\n", name))
    strings.write_string(&sb, "[dependencies]\n")
    strings.write_string(&sb, "build = [")
    for d, i in build_deps {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        strings.write_string(&sb, fmt.tprintf("\"%s\"", d))
    }
    strings.write_string(&sb, "]\nrun = [")
    for d, i in run_deps {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        strings.write_string(&sb, fmt.tprintf("\"%s\"", d))
    }
    strings.write_string(&sb, "]\n")
    // Minimal source tier so validation passes.
    strings.write_string(&sb, "[source.tarball]\nurl = \"https://example.com/x.tar.gz\"\nsha256 = \"abc\"\n")
    if werr := os.write_entire_file(path, strings.to_string(sb)); werr != nil {
        testing.fail_now(t)
    }
}

deps_opts :: proc(ports_root: string) -> Deps_Opts {
    repos := make([dynamic]string)
    append(&repos, "core")
    append(&repos, "extra")
    return Deps_Opts{ports_root = ports_root, repos = repos[:]}
}

// free_deps_opts releases a deps_opts result.
free_deps_opts :: proc(opts: ^Deps_Opts) {
    delete(opts.repos)
}

@(test)
test_deps_linear :: proc(t: ^testing.T) {
    root := deps_work_dir(t, "linear")
    defer delete(root)
    defer os.remove_all(root)
    // app -> lib -> base
    write_pkgsrc(t, root, "core", "base", {}, {})
    write_pkgsrc(t, root, "core", "lib", {}, {"base"})
    write_pkgsrc(t, root, "core", "app", {"lib"}, {})

    opts := deps_opts(root)
    defer free_deps_opts(&opts)
    plan, err := resolve_deps([]string{"app"}, &opts)
    defer free_dep_plan(&plan)
    testing.expect(t, err == "", "linear resolve should succeed")
    if err != "" {
        return
    }
    testing.expect(t, len(plan.names) == 3, "should have 3 packages")
    // Order: base, lib, app (deps first).
    testing.expect(t, plan.names[0] == "base", "base first")
    testing.expect(t, plan.names[1] == "lib", "lib second")
    testing.expect(t, plan.names[2] == "app", "app last")
}

@(test)
test_deps_diamond :: proc(t: ^testing.T) {
    root := deps_work_dir(t, "diamond")
    defer delete(root)
    defer os.remove_all(root)
    // app -> {liba, libb} -> base
    write_pkgsrc(t, root, "core", "base", {}, {})
    write_pkgsrc(t, root, "core", "liba", {}, {"base"})
    write_pkgsrc(t, root, "core", "libb", {}, {"base"})
    write_pkgsrc(t, root, "core", "app", {"liba", "libb"}, {})

    opts := deps_opts(root)
    defer free_deps_opts(&opts)
    plan, err := resolve_deps([]string{"app"}, &opts)
    defer free_dep_plan(&plan)
    testing.expect(t, err == "", "diamond resolve should succeed")
    if err != "" {
        return
    }
    testing.expect(t, len(plan.names) == 4, "should have 4 packages, no dupes")
    // base must come before liba, libb, app.
    pos := make(map[string]int)
    defer delete(pos)
    for n, i in plan.names {
        pos[n] = i
    }
    testing.expect(t, pos["base"] < pos["liba"], "base before liba")
    testing.expect(t, pos["base"] < pos["libb"], "base before libb")
    testing.expect(t, pos["liba"] < pos["app"], "liba before app")
    testing.expect(t, pos["libb"] < pos["app"], "libb before app")
}

@(test)
test_deps_cycle :: proc(t: ^testing.T) {
    root := deps_work_dir(t, "cycle")
    defer delete(root)
    defer os.remove_all(root)
    // a -> b -> c -> a
    write_pkgsrc(t, root, "core", "a", {"b"}, {})
    write_pkgsrc(t, root, "core", "b", {"c"}, {})
    write_pkgsrc(t, root, "core", "c", {"a"}, {})

    opts := deps_opts(root)
    defer free_deps_opts(&opts)
    plan, err := resolve_deps([]string{"a"}, &opts)
    defer free_dep_plan(&plan)
    testing.expect(t, err != "", "cycle should fail")
    testing.expect(t, strings.contains(err, "cycle"), "error should say 'cycle'")
    // The loop should be named.
    testing.expect(t, strings.contains(err, "a"), "error should name the loop")
}

@(test)
test_deps_missing :: proc(t: ^testing.T) {
    root := deps_work_dir(t, "missing")
    defer delete(root)
    defer os.remove_all(root)
    write_pkgsrc(t, root, "core", "app", {"ghost"}, {})

    opts := deps_opts(root)
    defer free_deps_opts(&opts)
    plan, err := resolve_deps([]string{"app"}, &opts)
    defer free_dep_plan(&plan)
    testing.expect(t, err != "", "missing dep should fail")
    testing.expect(t, strings.contains(err, "ghost"), "error should name the missing package")
}

@(test)
test_deps_core_containment :: proc(t: ^testing.T) {
    root := deps_work_dir(t, "containment")
    defer delete(root)
    defer os.remove_all(root)
    // core app depends on extra lib: forbidden.
    write_pkgsrc(t, root, "extra", "lib", {}, {})
    write_pkgsrc(t, root, "core", "app", {"lib"}, {})

    opts := deps_opts(root)
    defer free_deps_opts(&opts)
    plan, err := resolve_deps([]string{"app"}, &opts)
    defer free_dep_plan(&plan)
    testing.expect(t, err != "", "core-on-extra should fail")
    testing.expect(t, strings.contains(err, "core"), "error should mention core")
}

@(test)
test_deps_extra_on_core_ok :: proc(t: ^testing.T) {
    root := deps_work_dir(t, "extra-ok")
    defer delete(root)
    defer os.remove_all(root)
    // extra app depends on core lib: allowed.
    write_pkgsrc(t, root, "core", "lib", {}, {})
    write_pkgsrc(t, root, "extra", "app", {"lib"}, {})

    opts := deps_opts(root)
    defer free_deps_opts(&opts)
    plan, err := resolve_deps([]string{"app"}, &opts)
    defer free_dep_plan(&plan)
    testing.expect(t, err == "", "extra-on-core should succeed")
    if err != "" {
        return
    }
    testing.expect(t, len(plan.names) == 2, "should have 2 packages")
}
