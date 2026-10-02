// norn deps: dependency resolution.
//
// Given package names, loads their manifests from the local ports tree
// (/usr/ports/<repo>/.../<name>.pkgsrc), builds the dependency graph from
// [dependencies] build+run, and returns the install order: topological,
// dependencies before dependents.
//
// Rules (from the spec §7.4):
//   - Every dependency must be explicitly declared; a dep with no manifest
//     in the tree is a hard error.
//   - A core package may only depend on core packages (verified here).
//   - A dependency cycle is a hard error naming the loop.
//
// Memory: the returned plan owns its name strings; free with free_dep_plan.
// Error strings are borrowed, never deleted.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "norn:manifest"

// Deps_Opts configures resolution.
Deps_Opts :: struct {
    ports_root: string, // "/usr/ports"
    repos:      []string, // enabled subprojects in sync order, e.g. ["core","extra"]
}

// Dep_Plan is the resolved install order: names, dependencies first.
// manifest_dir[i] is the directory holding plan[i]'s manifest (for the
// core-containment check); both arrays are parallel and owned.
Dep_Plan :: struct {
    names:        [dynamic]string,
    manifest_dir: [dynamic]string, // repo subdir, e.g. "/usr/ports/core"
}

free_dep_plan :: proc(p: ^Dep_Plan) {
    for n in p.names {
        delete(n)
    }
    delete(p.names)
    for d in p.manifest_dir {
        delete(d)
    }
    delete(p.manifest_dir)
}

// resolve_deps returns the install order for the requested packages.
resolve_deps :: proc(requested: []string, opts: ^Deps_Opts) -> (plan: Dep_Plan, err: string) {
    // Load every reachable manifest.
    manifests := make(map[string]manifest.Manifest)
    defer {
        for _, &m in manifests {
            manifest_free(&m)
        }
        delete(manifests)
    }
    // repo_of[name] = subproject dir holding its manifest (for core check).
    repo_of := make(map[string]string)
    defer {
        for _, d in repo_of {
            delete(d)
        }
        delete(repo_of)
    }

    // Worklist: names to load.
    queue := make([dynamic]string)
    defer delete(queue)
    for r in requested {
        append(&queue, r)
    }
    for len(queue) > 0 {
        name := pop(&queue)
        if name in manifests {
            continue
        }
        m, repo_dir, lerr := load_manifest_for(name, opts)
        if lerr != "" {
            return {}, lerr
        }
        manifests[name] = m
        repo_of[name] = strings.clone(repo_dir)
        for d in m.deps.build {
            append(&queue, d)
        }
        for d in m.deps.run {
            append(&queue, d)
        }
    }

    // Core containment: every dep of a core package must be in core.
    for name, m in manifests {
        if !is_core_repo(repo_of[name], opts) {
            continue
        }
        for d in m.deps.build {
            if !is_core_repo(repo_of[d], opts) {
                return {}, fmt.tprintf("core package '%s' depends on non-core package '%s'", name, d)
            }
        }
        for d in m.deps.run {
            if !is_core_repo(repo_of[d], opts) {
                return {}, fmt.tprintf("core package '%s' depends on non-core package '%s'", name, d)
            }
        }
    }

    // Topological order via DFS; detects cycles and names the loop.
    ctx := Dep_Ctx{
        manifests = &manifests,
        state     = make(map[string]u8),
        stack     = make([dynamic]string),
        order     = make([dynamic]string),
    }
    defer delete(ctx.state)
    defer delete(ctx.stack)
    defer delete(ctx.order)

    // Deterministic: visit requested in order, then the rest.
    for r in requested {
        if e := dep_visit(&ctx, r); e != "" {
            return {}, e
        }
    }
    for name in manifests {
        if e := dep_visit(&ctx, name); e != "" {
            return {}, e
        }
    }

    // Build the owned plan.
    for n in ctx.order {
        append(&plan.names, strings.clone(n))
        append(&plan.manifest_dir, strings.clone(repo_of[n]))
    }
    return plan, ""
}

// Dep_Ctx carries DFS state for dep_visit.
Dep_Ctx :: struct {
    manifests: ^map[string]manifest.Manifest,
    state:     map[string]u8, // 0=unseen, 1=in-stack, 2=done
    stack:     [dynamic]string, // current DFS path, for cycle reporting
    order:     [dynamic]string, // output: topological order
}

// dep_visit is the DFS step. Returns "" or a cycle error naming the loop.
dep_visit :: proc(ctx: ^Dep_Ctx, name: string) -> string {
    switch ctx.state[name] {
    case 2:
        return ""
    case 1:
        // Cycle: extract the loop from the stack.
        loop := make([dynamic]string)
        defer delete(loop)
        in_loop := false
        for s in ctx.stack {
            if s == name {
                in_loop = true
            }
            if in_loop {
                append(&loop, s)
            }
        }
        append(&loop, name)
        return fmt.tprintf("dependency cycle: %s", strings.join(loop[:], " -> ", context.temp_allocator))
    }
    ctx.state[name] = 1
    append(&ctx.stack, name)
    m := ctx.manifests[name]
    for d in m.deps.build {
        if e := dep_visit(ctx, d); e != "" {
            return e
        }
    }
    for d in m.deps.run {
        if e := dep_visit(ctx, d); e != "" {
            return e
        }
    }
    pop(&ctx.stack)
    ctx.state[name] = 2
    append(&ctx.order, name)
    return ""
}

// load_manifest_for finds <name>.pkgsrc in the enabled subprojects and
// parses it. Returns the manifest and the subproject dir holding it.
// The manifest is owned; the dir string is borrowed from opts.
load_manifest_for :: proc(name: string, opts: ^Deps_Opts) -> (m: manifest.Manifest, repo_dir: string, err: string) {
    for repo in opts.repos {
        sub, _ := filepath.join([]string{opts.ports_root, repo})
        defer delete(sub)
        // Walk the subproject for <name>.pkgsrc.
        found := find_manifest(sub, name)
        if found != "" {
            defer delete(found)
            pm, perr := load_manifest_file(found)
            if perr != "" {
                return {}, "", perr
            }
            return pm, sub, ""
        }
    }
    return {}, "", fmt.tprintf("package '%s' not found in the ports tree (run 'norn sync'?)", name)
}

// find_manifest searches dir recursively for <name>.pkgsrc. Returns the
// path (owned) or "".
find_manifest :: proc(dir, name: string) -> string {
    want := fmt.tprintf("%s.pkgsrc", name)
    // tprintf temp; do NOT delete.
    f, oerr := os.open(dir)
    if oerr != nil {
        return ""
    }
    defer os.close(f)
    entries, rerr := os.read_directory(f, 0, context.allocator)
    if rerr != nil {
        return ""
    }
    defer {
        for e in entries {
            os.file_info_delete(e, context.allocator)
        }
        delete(entries)
    }
    for e in entries {
        if e.type == .Directory {
            if sub := find_manifest(e.fullpath, name); sub != "" {
                return sub
            }
        } else if e.name == want {
            return strings.clone(e.fullpath)
        }
    }
    return ""
}

// load_manifest_file parses a .pkgsrc file into an owned Manifest.
load_manifest_file :: proc(path: string) -> (m: manifest.Manifest, err: string) {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return {}, fmt.tprintf("cannot read %s: %v", path, rerr)
    }
    defer delete(data)
    doc, perr := manifest.parse_toml(string(data))
    defer manifest.toml_doc_destroy(&doc)
    if perr.msg != "" {
        return {}, fmt.tprintf("%s:%d: %s", path, perr.line, perr.msg)
    }
    // manifest_from_doc borrows; we need owned. For now, clone the
    // strings we need. (A full owned-load is future work.)
    base, merr := manifest.manifest_from_doc(&doc, path)
    if merr.msg != "" {
        return {}, fmt.tprintf("%s: %s: %s", path, merr.field, merr.msg)
    }
    return manifest_clone(&base), ""
}

// is_core_repo reports whether repo_dir is the core subproject.
is_core_repo :: proc(repo_dir: string, opts: ^Deps_Opts) -> bool {
    core, _ := filepath.join([]string{opts.ports_root, "core"})
    defer delete(core)
    return repo_dir == core
}

// manifest_clone deep-copies a Manifest (all owned strings).
manifest_clone :: proc(src: ^manifest.Manifest) -> manifest.Manifest {
    dst: manifest.Manifest
    dst.pkg.name = strings.clone(src.pkg.name)
    dst.pkg.version = strings.clone(src.pkg.version)
    dst.pkg.description = strings.clone(src.pkg.description)
    dst.pkg.url = strings.clone(src.pkg.url)
    dst.pkg.license = strings.clone(src.pkg.license)
    dst.pkg.priority = src.pkg.priority
    dst.pkg.release = src.pkg.release
    dst.repo.present = src.repo.present
    dst.repo.vcs = strings.clone(src.repo.vcs)
    dst.repo.url = strings.clone(src.repo.url)
    dst.repo.branch = strings.clone(src.repo.branch)
    dst.repo.last_known_tag = strings.clone(src.repo.last_known_tag)
    dst.repo.last_known_hash = strings.clone(src.repo.last_known_hash)
    dst.tarball.present = src.tarball.present
    dst.tarball.url = strings.clone(src.tarball.url)
    dst.tarball.sha256 = strings.clone(src.tarball.sha256)
    dst.binary.present = src.binary.present
    dst.binary.url = strings.clone(src.binary.url)
    dst.binary.sha256 = strings.clone(src.binary.sha256)
    dst.deps.build = make([]string, len(src.deps.build))
    for s, i in src.deps.build {
        dst.deps.build[i] = strings.clone(s)
    }
    dst.deps.run = make([]string, len(src.deps.run))
    for s, i in src.deps.run {
        dst.deps.run[i] = strings.clone(s)
    }
    // Build_Info has cflags_append []string.
    dst.build.cflags_append = make([]string, len(src.build.cflags_append))
    for s, i in src.build.cflags_append {
        dst.build.cflags_append[i] = strings.clone(s)
    }
    return dst
}

// manifest_free releases a manifest_clone result.
manifest_free :: proc(m: ^manifest.Manifest) {
    delete(m.pkg.name)
    delete(m.pkg.version)
    delete(m.pkg.description)
    delete(m.pkg.url)
    delete(m.pkg.license)
    delete(m.repo.vcs)
    delete(m.repo.url)
    delete(m.repo.branch)
    delete(m.repo.last_known_tag)
    delete(m.repo.last_known_hash)
    delete(m.tarball.url)
    delete(m.tarball.sha256)
    delete(m.binary.url)
    delete(m.binary.sha256)
    for s in m.deps.build {
        delete(s)
    }
    delete(m.deps.build)
    for s in m.deps.run {
        delete(s)
    }
    delete(m.deps.run)
    for s in m.build.cflags_append {
        delete(s)
    }
    delete(m.build.cflags_append)
}
