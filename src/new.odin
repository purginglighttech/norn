// norn new: scaffold a <name>.pkgsrc manifest from flags.
//
// The scripted counterpart to the interactive `norn --create-pkgsrc`
// wizard. Both share the New_Opts struct and the renderer below.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "norn:manifest"

New_Opts :: struct {
    out:           string,
    force:         bool,
    version:       string,
    release:       i64,
    description:   string,
    url:           string,
    license:       string,
    priority:      i64,
    tier:          string, // "", "repo", "tarball", "binary"
    vcs:           string,
    repo_url:      string,
    branch:        string,
    tag:           string,
    hash:          string,
    tarball_url:   string,
    binary_url:    string,
    sha256:        string,
    deps_build:    []string,
    deps_run:      []string,
    cflags_append: []string,
}

new_usage :: proc() {
    fmt.println("usage: norn new <name> [flags]")
    fmt.println()
    fmt.println("Scaffold a <name>.pkgsrc manifest. Flags pre-fill fields;")
    fmt.println("anything left out is emitted commented for you to fill in.")
    fmt.println("For a guided walkthrough instead, run: norn --create-pkgsrc")
    fmt.println()
    fmt.println("flags:")
    fmt.println("  --out DIR            write the file into DIR (default: .)")
    fmt.println("  --force              overwrite an existing <name>.pkgsrc")
    fmt.println("  --version VER        package version (default: 0.1)")
    fmt.println("  --release N          package release (default: 1)")
    fmt.println("  --description TEXT   one-line description")
    fmt.println("  --url URL            upstream homepage")
    fmt.println("  --license SPDX       license identifier")
    fmt.println("  --priority N         live-tree provider priority (default: 50)")
    fmt.println("  --vcs jj|fossil      VCS for the repo tier (default: jj)")
    fmt.println("  --repo URL           source tier: VCS repository")
    fmt.println("  --branch B           VCS branch (default: upstream default)")
    fmt.println("  --tag T --hash H     last-known-good fallback for the repo tier")
    fmt.println("  --tarball URL        source tier: stable release tarball")
    fmt.println("  --binary URL         source tier: prebuilt binary package")
    fmt.println("  --sha256 H           expected hash (tarball and binary tiers)")
    fmt.println("  --build-dep A,B      build dependencies (comma-separated)")
    fmt.println("  --run-dep A,B        runtime dependencies (comma-separated)")
    fmt.println("  --cflags A,B         extra CFLAGS to append (comma-separated)")
    fmt.println()
    fmt.println("At most one source tier per invocation. With no tier flags,")
    fmt.println("all three tiers are emitted commented out.")
}

cmd_new :: proc(_: ^Config, args: []string) {
    if len(args) == 0 {
        new_usage()
        os.exit(1)
    }
    name := args[0]
    if !valid_pkg_name(name) {
        fmt.eprintf("norn new: invalid package name '%s'\n", name)
        os.exit(1)
    }

    o := New_Opts{
        out      = ".",
        version  = "0.1",
        release  = 1,
        priority = 50,
        vcs      = "jj",
    }

    rest := args[1:]
    i := 0
    for i < len(rest) {
        a := rest[i]
        if !strings.has_prefix(a, "--") {
            fmt.eprintf("norn new: unexpected argument '%s'\n", a)
            os.exit(1)
        }
        key, val, has_value := split_flag(rest, &i)
        switch key {
        case "out":
            o.out = take_value(key, val, has_value, rest, &i)
        case "version":
            o.version = take_value(key, val, has_value, rest, &i)
        case "release":
            o.release = parse_i64_flag(key, take_value(key, val, has_value, rest, &i))
        case "description":
            o.description = take_value(key, val, has_value, rest, &i)
        case "url":
            o.url = take_value(key, val, has_value, rest, &i)
        case "license":
            o.license = take_value(key, val, has_value, rest, &i)
        case "priority":
            o.priority = parse_i64_flag(key, take_value(key, val, has_value, rest, &i))
        case "force":
            o.force = true
        case "vcs":
            o.vcs = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "repo")
        case "repo":
            o.repo_url = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "repo")
        case "branch":
            o.branch = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "repo")
        case "tag":
            o.tag = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "repo")
        case "hash":
            o.hash = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "repo")
        case "tarball":
            o.tarball_url = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "tarball")
        case "binary":
            o.binary_url = take_value(key, val, has_value, rest, &i)
            o.tier = set_tier(o.tier, "binary")
        case "sha256":
            o.sha256 = take_value(key, val, has_value, rest, &i)
        case "build-dep":
            o.deps_build = split_csv(take_value(key, val, has_value, rest, &i))
        case "run-dep":
            o.deps_run = split_csv(take_value(key, val, has_value, rest, &i))
        case "cflags":
            o.cflags_append = split_csv(take_value(key, val, has_value, rest, &i))
        case "help", "h":
            new_usage()
            return
        case:
            fmt.eprintf("norn new: unknown flag '--%s'\n", key)
            os.exit(1)
        }
    }

    // Post-parse validation: the selected tier must be complete, and a
    // --sha256 only makes sense with the tarball or binary tier.
    switch o.tier {
    case "repo":
        if o.repo_url == "" {
            fmt.eprintln("norn new: the repo tier requires --repo URL")
            os.exit(1)
        }
        if !manifest.is_known_vcs(o.vcs) {
            fmt.eprintf("norn new: unknown VCS '%s'\n", o.vcs)
            os.exit(1)
        }
    case "tarball":
        if o.tarball_url == "" || o.sha256 == "" {
            fmt.eprintln("norn new: the tarball tier requires --tarball URL and --sha256 HASH")
            os.exit(1)
        }
    case "binary":
        if o.binary_url == "" || o.sha256 == "" {
            fmt.eprintln("norn new: the binary tier requires --binary URL and --sha256 HASH")
            os.exit(1)
        }
    case "":
        if o.sha256 != "" {
            fmt.eprintln("norn new: --sha256 requires --tarball or --binary")
            os.exit(1)
        }
    }

    path := pkgsrc_path(name, o.out)
    if os.exists(path) && !o.force {
        fmt.eprintf("norn new: '%s' already exists (use --force to overwrite)\n", path)
        os.exit(1)
    }

    text := render_pkgsrc(name, &o)
    defer delete(text)
    if err := os.write_entire_file(path, transmute([]byte)text); err != nil {
        fmt.eprintf("norn new: cannot write '%s': %v\n", path, err)
        os.exit(1)
    }
    fmt.printf("wrote %s\n", path)
    if o.tier == "" {
        fmt.println("no source tier selected: uncomment one tier before building.")
    }
}

// pkgsrc_path resolves the output file for a manifest name and directory.
pkgsrc_path :: proc(name, out: string) -> string {
    if out == "." || out == "" {
        return fmt.tprintf("%s.pkgsrc", name)
    }
    return fmt.tprintf("%s/%s.pkgsrc", out, name)
}

// split_flag parses one argv element of the form --key=value or --key value.
// has_value is false for a bare --key.
split_flag :: proc(args: []string, i: ^int) -> (key, val: string, has_value: bool) {
    a := args[i^]
    i^ += 1
    rest := a[2:] // caller guarantees the "--" prefix
    if eq := strings.index_byte(rest, '='); eq >= 0 {
        return rest[:eq], rest[eq+1:], true
    }
    return rest, "", false
}

// take_value resolves a flag's value from --key=value or the next argument.
take_value :: proc(key: string, val: string, has_value: bool, args: []string, i: ^int) -> string {
    if has_value {
        return val
    }
    if i^ >= len(args) {
        fmt.eprintf("norn new: --%s requires a value\n", key)
        os.exit(1)
    }
    v := args[i^]
    i^ += 1
    return v
}

parse_i64_flag :: proc(key, val: string) -> i64 {
    n, ok := strconv.parse_i64(val)
    if !ok {
        fmt.eprintf("norn new: --%s expects an integer, got '%s'\n", key, val)
        os.exit(1)
    }
    return n
}

// set_tier records the chosen source tier, rejecting a second tier.
set_tier :: proc(cur, want: string) -> string {
    if cur != "" && cur != want {
        fmt.eprintf("norn new: only one source tier per invocation (have '%s', got '%s')\n", cur, want)
        os.exit(1)
    }
    return want
}

valid_pkg_name :: proc(name: string) -> bool {
    if name == "" || name == "." || name == ".." {
        return false
    }
    return !strings.contains_any(name, "/\\ \t\r\n")
}

// split_csv splits a comma-separated answer into trimmed, non-empty items.
split_csv :: proc(s: string) -> []string {
    if strings.trim_space(s) == "" {
        return nil
    }
    parts := strings.split(s, ",")
    defer delete(parts)
    out := make([dynamic]string, 0, len(parts), context.allocator)
    for p in parts {
        t := strings.trim_space(p)
        if t != "" {
            append(&out, t)
        }
    }
    return out[:]
}

// toml_write_escaped writes s as a quoted string for the restricted TOML
// subset, escaping what the subset requires.
toml_write_escaped :: proc(sb: ^strings.Builder, s: string) {
    strings.write_string(sb, "\"")
    for c in s {
        switch c {
        case '\\':
            strings.write_string(sb, "\\\\")
        case '"':
            strings.write_string(sb, "\\\"")
        case '\n':
            strings.write_string(sb, "\\n")
        case '\t':
            strings.write_string(sb, "\\t")
        case '\r':
            strings.write_string(sb, "\\r")
        case:
            strings.write_rune(sb, c)
        }
    }
    strings.write_string(sb, "\"")
}

// toml_escape quotes a string for the restricted TOML subset. The caller
// owns the result.
toml_escape :: proc(s: string) -> string {
    sb: strings.Builder
    strings.builder_init(&sb)
    toml_write_escaped(&sb, s)
    // Ownership of the buffer passes to the caller; the builder is spent.
    return strings.to_string(sb)
}

// render_str_array writes ["a", "b"] for the restricted TOML subset.
render_str_array :: proc(sb: ^strings.Builder, vals: []string) {
    strings.write_string(sb, "[")
    for v, i in vals {
        if i > 0 {
            strings.write_string(sb, ", ")
        }
        toml_write_escaped(sb, v)
    }
    strings.write_string(sb, "]")
}

// render_pkgsrc assembles the manifest text. The selected tier is active;
// the others are emitted commented so the file teaches the schema.
render_pkgsrc :: proc(name: string, o: ^New_Opts) -> string {
    sb: strings.Builder
    strings.builder_init(&sb)
    w := strings.write_string

    w(&sb, "# ")
    w(&sb, name)
    w(&sb, ".pkgsrc - norn package manifest.\n#\n")
    w(&sb, "# Restricted TOML subset: [tables] and subtables, strings, integers,\n")
    w(&sb, "# booleans, arrays of strings. No inline tables, floats, datetimes,\n")
    w(&sb, "# or dotted keys.\n\n")

    w(&sb, "[package]\n")
    w(&sb, "name = ")
    toml_write_escaped(&sb, name)
    w(&sb, "\nversion = ")
    toml_write_escaped(&sb, o.version)
    fmt.sbprintf(&sb, "\nrelease = %d\n", o.release)
    w(&sb, "description = ")
    toml_write_escaped(&sb, o.description)
    w(&sb, "\nurl = ")
    toml_write_escaped(&sb, o.url)
    w(&sb, "\nlicense = ")
    toml_write_escaped(&sb, o.license)
    w(&sb, "\n# Live-tree provider priority: higher wins when two packages ship\n")
    w(&sb, "# the same path. Distro default is 50.\n")
    fmt.sbprintf(&sb, "priority = %d\n", o.priority)

    w(&sb, "\n# --- source ----------------------------------------------------\n")
    w(&sb, "# Declare the primary tier here. Fallback tiers can be added later;\n")
    w(&sb, "# norn tries them in priority order: repo, then tarball, then binary.\n\n")

    render_repo_tier(&sb, o)
    w(&sb, "\n")
    render_tarball_tier(&sb, o)
    w(&sb, "\n")
    render_binary_tier(&sb, o)

    // A non-core VCS client must be installed before fetching, so it is
    // declared in dependencies.build automatically. vcs_dep is procedure-
    // scoped (not block-scoped) so build_deps never dangles: Odin's defer
    // runs at the end of its block, not the procedure.
    vcs_dep: [dynamic]string
    defer delete(vcs_dep)
    build_deps := o.deps_build
    if o.tier == "repo" && !manifest.is_core_vcs(o.vcs) {
        vcs_dep = make([dynamic]string, 0, len(build_deps)+1, context.allocator)
        append(&vcs_dep, o.vcs)
        append_elems(&vcs_dep, ..build_deps)
        build_deps = vcs_dep[:]
        w(&sb, "\n# NOTE: this VCS is not in core; it was added to\n")
        w(&sb, "# dependencies.build automatically.\n")
    }

    w(&sb, "\n[dependencies]\nbuild = ")
    render_str_array(&sb, build_deps)
    w(&sb, "\nrun = ")
    render_str_array(&sb, o.deps_run)
    w(&sb, "\n")

    w(&sb, "\n[build]\n")
    w(&sb, "# Extra flags appended to the system build profile (/etc/norn/build.conf).\n")
    w(&sb, "# Distro policy is authoritative: manifests may append, never replace.\n")
    w(&sb, "cflags_append = ")
    render_str_array(&sb, o.cflags_append)
    w(&sb, "\n")

    return strings.to_string(sb)
}

render_repo_tier :: proc(sb: ^strings.Builder, o: ^New_Opts) {
    w := strings.write_string
    if o.tier == "repo" {
        w(sb, "[source.repo]\n")
        w(sb, "vcs = ")
        toml_write_escaped(sb, o.vcs)
        w(sb, "\nurl = ")
        toml_write_escaped(sb, o.repo_url)
        w(sb, "\n")
        if o.branch != "" {
            w(sb, "branch = ")
            toml_write_escaped(sb, o.branch)
            w(sb, "\n")
        } else {
            w(sb, "# branch = \"main\"\n")
        }
        if o.tag != "" {
            w(sb, "last_known_tag = ")
            toml_write_escaped(sb, o.tag)
            w(sb, "\n")
        } else {
            w(sb, "# last_known_tag = \"\"    # fallback tag if HEAD fails to build\n")
        }
        if o.hash != "" {
            w(sb, "last_known_hash = ")
            toml_write_escaped(sb, o.hash)
            w(sb, "\n")
        } else {
            w(sb, "# last_known_hash = \"\"  # expected hash of the fallback tag\n")
        }
        return
    }
    w(sb, "# [source.repo]\n")
    w(sb, "# vcs = \"jj\"              # core: jj, fossil - others need a build dep\n")
    w(sb, "# url = \"\"\n")
    w(sb, "# branch = \"main\"\n")
    w(sb, "# last_known_tag = \"\"    # fallback tag if HEAD fails to build\n")
    w(sb, "# last_known_hash = \"\"  # expected hash of the fallback tag\n")
}

render_tarball_tier :: proc(sb: ^strings.Builder, o: ^New_Opts) {
    w := strings.write_string
    if o.tier == "tarball" {
        w(sb, "[source.tarball]\n")
        w(sb, "url = ")
        toml_write_escaped(sb, o.tarball_url)
        w(sb, "\nsha256 = ")
        toml_write_escaped(sb, o.sha256)
        w(sb, "\n")
        return
    }
    w(sb, "# [source.tarball]\n")
    w(sb, "# url = \"\"\n")
    w(sb, "# sha256 = \"\"\n")
}

render_binary_tier :: proc(sb: ^strings.Builder, o: ^New_Opts) {
    w := strings.write_string
    if o.tier == "binary" {
        w(sb, "[source.binary]\n")
        w(sb, "url = ")
        toml_write_escaped(sb, o.binary_url)
        w(sb, "\nsha256 = ")
        toml_write_escaped(sb, o.sha256)
        w(sb, "\n")
        return
    }
    w(sb, "# [source.binary]\n")
    w(sb, "# url = \"\"\n")
    w(sb, "# sha256 = \"\"\n")
}
