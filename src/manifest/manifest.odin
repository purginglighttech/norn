package manifest

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Recognized VCS values. Only jj and fossil ship in the distro core;
// anything else must be declared in dependencies.build so the client is
// installed before norn tries to fetch with it.
KNOWN_VCS :: []string{"jj", "fossil", "git", "hg", "bzr", "darcs", "svn"}
CORE_VCS  :: []string{"jj", "fossil"}

Package_Info :: struct {
    name:        string,
    version:     string,
    release:     i64,
    description: string,
    url:         string,
    license:     string,
    priority:    i64,
}

Source_Repo :: struct {
    present:         bool,
    vcs:             string,
    url:             string,
    branch:          string,
    last_known_tag:  string,
    last_known_hash: string,
}

Source_Tarball :: struct {
    present: bool,
    url:     string,
    sha256:  string,
}

Source_Binary :: struct {
    present: bool,
    url:     string,
    sha256:  string,
}

Dependencies :: struct {
    build: []string,
    run:   []string,
}

Build_Info :: struct {
    cflags_append: []string,
}

Manifest :: struct {
    pkg: Package_Info,
    repo:    Source_Repo,
    tarball: Source_Tarball,
    binary:  Source_Binary,
    deps:    Dependencies,
    build:   Build_Info,
}

Manifest_Error :: struct {
    field: string,
    msg:   string,
}

is_known_vcs :: proc(vcs: string) -> bool {
    for k in KNOWN_VCS {
        if k == vcs {
            return true
        }
    }
    return false
}

is_core_vcs :: proc(vcs: string) -> bool {
    for k in CORE_VCS {
        if k == vcs {
            return true
        }
    }
    return false
}

slice_contains :: proc(s: []string, want: string) -> bool {
    for x in s {
        if x == want {
            return true
        }
    }
    return false
}

// manifest_from_doc binds a parsed TOML document to the manifest schema
// and enforces the validation rules. filename is used to check that
// package.name matches the <name>.pkgsrc stem.
//
// The returned Manifest BORROWS all of its strings and arrays from doc:
// it owns nothing. doc must outlive m — destroy the document only after
// the manifest is no longer used. For an owned Manifest, see
// load_manifest (which returns one via manifest_clone).
manifest_from_doc :: proc(doc: ^Toml_Doc, filename: string) -> (m: Manifest, err: Manifest_Error) {
    stem := strings.trim_suffix(filepath.base(filename), ".pkgsrc")

    name, ok := req_string(doc, &err, "package.name")
    if !ok {
        return m, err
    }
    if name != stem {
        return m, Manifest_Error{"package.name", "package name does not match manifest filename"}
    }
    m.pkg.name = name

    m.pkg.version, ok = req_string(doc, &err, "package.version")
    if !ok {
        return m, err
    }

    rel, ok2 := req_int(doc, &err, "package.release")
    if !ok2 {
        return m, err
    }
    m.pkg.release = rel

    m.pkg.description = opt_string(doc, "package.description")
    m.pkg.url         = opt_string(doc, "package.url")
    m.pkg.license     = opt_string(doc, "package.license")
    m.pkg.priority, _ = opt_int(doc, "package.priority")

    _, has_repo := doc.values["source.repo.vcs"]
    _, has_tb   := doc.values["source.tarball.url"]
    _, has_bin  := doc.values["source.binary.url"]
    if !has_repo && !has_tb && !has_bin {
        return m, Manifest_Error{"source", "at least one source tier (repo, tarball, binary) is required"}
    }

    if has_repo {
        m.repo.present = true
        m.repo.vcs, ok = req_string(doc, &err, "source.repo.vcs")
        if !ok {
            return m, err
        }
        if !is_known_vcs(m.repo.vcs) {
            return m, Manifest_Error{"source.repo.vcs", "unrecognized VCS"}
        }
        m.repo.url, ok = req_string(doc, &err, "source.repo.url")
        if !ok {
            return m, err
        }
        m.repo.branch          = opt_string(doc, "source.repo.branch")
        m.repo.last_known_tag  = opt_string(doc, "source.repo.last_known_tag")
        m.repo.last_known_hash = opt_string(doc, "source.repo.last_known_hash")
    }
    if has_tb {
        m.tarball.present = true
        m.tarball.url, ok = req_string(doc, &err, "source.tarball.url")
        if !ok {
            return m, err
        }
        m.tarball.sha256, ok = req_string(doc, &err, "source.tarball.sha256")
        if !ok {
            return m, err
        }
    }
    if has_bin {
        m.binary.present = true
        m.binary.url, ok = req_string(doc, &err, "source.binary.url")
        if !ok {
            return m, err
        }
        m.binary.sha256, ok = req_string(doc, &err, "source.binary.sha256")
        if !ok {
            return m, err
        }
    }

    m.deps.build, _ = opt_str_array(doc, "dependencies.build")
    m.deps.run, _   = opt_str_array(doc, "dependencies.run")

    // A non-core VCS client must be declared as a build dependency so it
    // is installed before norn tries to fetch with it.
    if m.repo.present && !is_core_vcs(m.repo.vcs) && !slice_contains(m.deps.build, m.repo.vcs) {
        return m, Manifest_Error{"source.repo.vcs", "non-core VCS client must be declared in dependencies.build"}
    }

    m.build.cflags_append, _ = opt_str_array(doc, "build.cflags_append")

    return m, Manifest_Error{}
}

// load_manifest reads, parses, and validates a .pkgsrc file.
// The returned Manifest is owned by the caller: release it with
// manifest_destroy when done.
load_manifest :: proc(path: string) -> (m: Manifest, err: string) {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return m, fmt.tprintf("cannot read file: %s", path)
    }
    defer delete(data)

    doc, perr := parse_toml(string(data))
    defer toml_doc_destroy(&doc)
    if perr.msg != "" {
        return m, fmt.tprintf("%s:%d: %s", path, perr.line, perr.msg)
    }
    vm, merr := manifest_from_doc(&doc, path)
    if merr.msg != "" {
        return m, fmt.tprintf("%s: %s: %s", path, merr.field, merr.msg)
    }
    // vm borrows from doc, which is destroyed above: hand back an
    // owned deep copy.
    return manifest_clone(&vm), ""
}

// clone_string_array deep-copies a string array: new backing array and
// freshly allocated element strings. A nil array stays nil.
clone_string_array :: proc(s: []string) -> []string {
    if s == nil {
        return nil
    }
    out := make([]string, len(s), context.allocator)
    for v, i in s {
        out[i] = strings.clone(v)
    }
    return out
}

free_string_array :: proc(s: []string) {
    for e in s {
        delete(e)
    }
    delete(s)
}

// manifest_clone deep-copies a Manifest so the copy owns all of its
// strings and arrays. Pair with manifest_destroy.
manifest_clone :: proc(m: ^Manifest) -> Manifest {
    c := m^
    c.pkg.name        = strings.clone(m.pkg.name)
    c.pkg.version     = strings.clone(m.pkg.version)
    c.pkg.description = strings.clone(m.pkg.description)
    c.pkg.url         = strings.clone(m.pkg.url)
    c.pkg.license     = strings.clone(m.pkg.license)
    c.repo.vcs             = strings.clone(m.repo.vcs)
    c.repo.url             = strings.clone(m.repo.url)
    c.repo.branch          = strings.clone(m.repo.branch)
    c.repo.last_known_tag  = strings.clone(m.repo.last_known_tag)
    c.repo.last_known_hash = strings.clone(m.repo.last_known_hash)
    c.tarball.url    = strings.clone(m.tarball.url)
    c.tarball.sha256 = strings.clone(m.tarball.sha256)
    c.binary.url     = strings.clone(m.binary.url)
    c.binary.sha256  = strings.clone(m.binary.sha256)
    c.deps.build          = clone_string_array(m.deps.build)
    c.deps.run            = clone_string_array(m.deps.run)
    c.build.cflags_append = clone_string_array(m.build.cflags_append)
    return c
}

// manifest_destroy frees every allocation owned by a Manifest produced
// by manifest_clone or load_manifest. It is safe on a zero Manifest.
// Do NOT call it on a Manifest borrowed from manifest_from_doc — that
// one owns nothing; destroy its document instead.
manifest_destroy :: proc(m: ^Manifest) {
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
    free_string_array(m.deps.build)
    free_string_array(m.deps.run)
    free_string_array(m.build.cflags_append)
}

req_string :: proc(doc: ^Toml_Doc, err: ^Manifest_Error, key: string) -> (string, bool) {
    v, found := doc.values[key]
    if !found {
        err^ = Manifest_Error{key, "missing required field"}
        return "", false
    }
    s, is_str := v.(string)
    if !is_str {
        err^ = Manifest_Error{key, "expected a string"}
        return "", false
    }
    return s, true
}

req_int :: proc(doc: ^Toml_Doc, err: ^Manifest_Error, key: string) -> (i64, bool) {
    v, found := doc.values[key]
    if !found {
        err^ = Manifest_Error{key, "missing required field"}
        return 0, false
    }
    n, is_int := v.(i64)
    if !is_int {
        err^ = Manifest_Error{key, "expected an integer"}
        return 0, false
    }
    return n, true
}

opt_string :: proc(doc: ^Toml_Doc, key: string) -> string {
    v, found := doc.values[key]
    if !found {
        return ""
    }
    s, _ := v.(string)
    return s
}

opt_int :: proc(doc: ^Toml_Doc, key: string) -> (i64, bool) {
    v, found := doc.values[key]
    if !found {
        return 0, false
    }
    n, is_int := v.(i64)
    if !is_int {
        return 0, false
    }
    return n, true
}

opt_str_array :: proc(doc: ^Toml_Doc, key: string) -> ([]string, bool) {
    v, found := doc.values[key]
    if !found {
        return nil, false
    }
    a, is_arr := v.([]string)
    if !is_arr {
        return nil, false
    }
    return a, true
}
