// norn build: run a package's [build] script in a clean directory.
//
// The system build profile comes from /etc/norn/build.conf:
//   [toolchain] cc, cxx, cflags, cxxflags, ldflags (all required)
//   [build]     jobs, strip, debug, builddir
//
// Layered resolution: the manifest's [build] may set cc/cxx/cflags/
// cxxflags/ldflags, each REPLACING the build.conf value outright. Unset
// keys come from build.conf. cflags_append/cxxflags_append/ldflags_append
// apply after override resolution. jobs/strip/debug/builddir are
// build.conf-only.
//
// The script runs via the POSIX shell with working dir $SRCDIR and:
//   $PREFIX  /usr/apps/<name>/<version> (or under --sysroot)
//   $SRCDIR  the fetched source directory
//   $JOBS, $CC, $CXX, $CFLAGS, $CXXFLAGS, $LDFLAGS, $MAKEFLAGS
// If $NORN_FAKEROOT is set, it is exported as LD_PRELOAD (the §7.5 shim
// hook); the shim itself is a separate project.
//
// A source tier (repo/tarball) with no [build] script is a build-time
// error. The binary tier ignores the script.
//
// Memory: Build_Profile owns its strings; free with free_build_profile.
// Error strings are borrowed, never deleted.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "norn:manifest"

// BUILD_CONF_PATH is the system build profile (host-side, never sysrooted).
BUILD_CONF_PATH :: "/etc/norn/build.conf"

// Build_Profile is the resolved toolchain + build settings.
Build_Profile :: struct {
    cc:       string,
    cxx:      string,
    cflags:   string,
    cxxflags: string,
    ldflags:  string,
    jobs:     int,
    strip:    bool,
    debug:    bool,
    builddir: string,
}

free_build_profile :: proc(p: ^Build_Profile) {
    delete(p.cc)
    delete(p.cxx)
    delete(p.cflags)
    delete(p.cxxflags)
    delete(p.ldflags)
    delete(p.builddir)
}

// load_build_conf reads /etc/norn/build.conf. All [toolchain] keys and
// [build] keys are required; a missing key is a config error.
load_build_conf :: proc(path: string) -> (p: Build_Profile, err: string) {
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

    get_str := proc(doc: ^manifest.Toml_Doc, path, key: string) -> (string, string) {
        v, found := doc.values[key]
        if !found {
            return "", fmt.tprintf("%s: missing required key '%s'", path, key)
        }
        s, is_str := v.(string)
        if !is_str {
            return "", fmt.tprintf("%s: '%s' must be a string", path, key)
        }
        return strings.clone(s), ""
    }

    e: string
    if p.cc, e = get_str(&doc, path, "toolchain.cc"); e != "" {
        return {}, e
    }
    if p.cxx, e = get_str(&doc, path, "toolchain.cxx"); e != "" {
        free_build_profile(&p)
        return {}, e
    }
    if p.cflags, e = get_str(&doc, path, "toolchain.cflags"); e != "" {
        free_build_profile(&p)
        return {}, e
    }
    if p.cxxflags, e = get_str(&doc, path, "toolchain.cxxflags"); e != "" {
        free_build_profile(&p)
        return {}, e
    }
    if p.ldflags, e = get_str(&doc, path, "toolchain.ldflags"); e != "" {
        free_build_profile(&p)
        return {}, e
    }
    if p.builddir, e = get_str(&doc, path, "build.builddir"); e != "" {
        free_build_profile(&p)
        return {}, e
    }

    // jobs: integer, 0 = ncpu.
    if v, found := doc.values["build.jobs"]; found {
        i, is_int := v.(i64)
        if !is_int {
            free_build_profile(&p)
            return {}, fmt.tprintf("%s: 'build.jobs' must be an integer", path)
        }
        p.jobs = int(i)
    } else {
        free_build_profile(&p)
        return {}, fmt.tprintf("%s: missing required key 'build.jobs'", path)
    }
    if p.jobs == 0 {
        p.jobs = os.get_processor_core_count()
    }

    // strip, debug: booleans.
    get_bool := proc(doc: ^manifest.Toml_Doc, path, key: string) -> (bool, string) {
        v, found := doc.values[key]
        if !found {
            return false, fmt.tprintf("%s: missing required key '%s'", path, key)
        }
        b, is_bool := v.(bool)
        if !is_bool {
            return false, fmt.tprintf("%s: '%s' must be a boolean", path, key)
        }
        return b, ""
    }
    if p.strip, e = get_bool(&doc, path, "build.strip"); e != "" {
        free_build_profile(&p)
        return {}, e
    }
    if p.debug, e = get_bool(&doc, path, "build.debug"); e != "" {
        free_build_profile(&p)
        return {}, e
    }

    return p, ""
}

// resolve_toolchain applies the manifest's [build] overrides to the
// build.conf profile. Manifest keys replace outright; *_append arrays
// apply after. The result owns its strings; free with free_build_profile.
// Overrides are logged via the log proc (may be nil).
resolve_toolchain :: proc(base: ^Build_Profile, m: ^manifest.Manifest, log: proc(fmt_str: string, args: ..any)) -> Build_Profile {
    out: Build_Profile
    out.jobs = base.jobs
    out.strip = base.strip
    out.debug = base.debug
    out.builddir = strings.clone(base.builddir)

    pick := proc(log: proc(fmt_str: string, args: ..any), label, manifest_val, base_val: string) -> string {
        if manifest_val != "" {
            if log != nil {
                log("build: manifest overrides %s (build.conf value replaced)", label)
            }
            return strings.clone(manifest_val)
        }
        return strings.clone(base_val)
    }
    out.cc = pick(log, "cc", m.build.cc, base.cc)
    out.cxx = pick(log, "cxx", m.build.cxx, base.cxx)

    // cflags/cxxflags/ldflags: replace, then append.
    append_flags := proc(base_flags: string, extra: []string) -> string {
        if len(extra) == 0 {
            return strings.clone(base_flags)
        }
        sb: strings.Builder
        strings.builder_init(&sb)
        strings.write_string(&sb, base_flags)
        for f in extra {
            strings.write_byte(&sb, ' ')
            strings.write_string(&sb, f)
        }
        s := strings.clone(strings.to_string(sb))
        strings.builder_destroy(&sb)
        return s
    }
    cflags_base := pick(log, "cflags", m.build.cflags, base.cflags)
    defer delete(cflags_base)
    out.cflags = append_flags(cflags_base, m.build.cflags_append)

    cxxflags_base := pick(log, "cxxflags", m.build.cxxflags, base.cxxflags)
    defer delete(cxxflags_base)
    out.cxxflags = append_flags(cxxflags_base, m.build.cxxflags_append)

    ldflags_base := pick(log, "ldflags", m.build.ldflags, base.ldflags)
    defer delete(ldflags_base)
    out.ldflags = append_flags(ldflags_base, m.build.ldflags_append)

    return out
}

// Build_Opts configures a build run.
Build_Opts :: struct {
    sysroot:      string, // "/" for live; target paths resolve under here
    fakeroot_shim: string, // path to LD_PRELOAD shim; "" = none
    shell_bin:    string, // "/bin/sh"
}

// run_build executes the manifest's [build] script for a source-tier
// package. srcdir is the fetched source; the script runs with cwd=srcdir
// and installs directly into $PREFIX. Returns "" on success.
run_build :: proc(m: ^manifest.Manifest, srcdir: string, prof: ^Build_Profile, opts: ^Build_Opts) -> string {
    // Binary tier ignores the script.
    if m.binary.present && !m.repo.present && !m.tarball.present {
        return ""
    }
    if m.build.script == "" {
        return fmt.tprintf("build: package '%s' selects a source tier but has no [build] script", m.pkg.name)
    }

    prefix := build_prefix(m, opts.sysroot)
    defer delete(prefix)

    // Ensure the prefix exists.
    if merr := os.make_directory_all(prefix); merr != nil {
        return fmt.tprintf("build: cannot create $PREFIX '%s': %v", prefix, merr)
    }

    // Build environment.
    env := make(map[string]string)
    defer {
        for _, v in env {
            delete(v)
        }
        delete(env)
    }
    env["PREFIX"] = strings.clone(prefix)
    env["SRCDIR"] = strings.clone(srcdir)
    env["JOBS"] = strings.clone(fmt.tprintf("%d", prof.jobs))
    env["CC"] = strings.clone(prof.cc)
    env["CXX"] = strings.clone(prof.cxx)
    env["CFLAGS"] = strings.clone(prof.cflags)
    env["CXXFLAGS"] = strings.clone(prof.cxxflags)
    env["LDFLAGS"] = strings.clone(prof.ldflags)
    env["MAKEFLAGS"] = strings.clone(fmt.tprintf("-j%d", prof.jobs))
    if opts.fakeroot_shim != "" {
        env["LD_PRELOAD"] = strings.clone(opts.fakeroot_shim)
    }
    // debug=true appends -g and skips strip (strip is M6 install concern;
    // here we just set the flags).
    if prof.debug {
        cflags := fmt.tprintf("%s -g", env["CFLAGS"])
        delete(env["CFLAGS"])
        env["CFLAGS"] = strings.clone(cflags)
    }

    // Convert env map to ["KEY=val", ...] for process_exec.
    env_list := make([dynamic]string)
    defer {
        for s in env_list {
            delete(s)
        }
        delete(env_list)
    }
    for k, v in env {
        append(&env_list, fmt.aprintf("%s=%s", k, v))
    }

    // Run: /bin/sh -c '<script>' with cwd=srcdir.
    cmd := []string{opts.shell_bin, "-c", m.build.script}
    state, out, err_out, perr := os.process_exec(
        os.Process_Desc{
            working_dir = srcdir,
            command     = cmd,
            env         = env_list[:],
        },
        context.allocator,
    )
    defer delete(out)
    defer delete(err_out)
    if perr != nil {
        return fmt.tprintf("build: cannot execute script: %v", perr)
    }
    if !state.exited || state.exit_code != 0 {
        detail := strings.trim_space(string(err_out))
        if detail == "" {
            detail = strings.trim_space(string(out))
        }
        return fmt.tprintf("build: script failed (exit %d): %s", state.exit_code, detail)
    }
    return ""
}

// build_prefix returns /usr/apps/<name>/<version> under sysroot.
// The result is owned; delete it.
build_prefix :: proc(m: ^manifest.Manifest, sysroot: string) -> string {
    if sysroot == "" || sysroot == "/" {
        return fmt.aprintf("/usr/apps/%s/%s", m.pkg.name, m.pkg.version)
    }
    return fmt.aprintf("%s/usr/apps/%s/%s", strings.trim_suffix(sysroot, "/"), m.pkg.name, m.pkg.version)
}
