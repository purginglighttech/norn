// norn sync: synchronize the manifest tree.
//
// The tree is a super-project ("ports") composed of subprojects (core,
// extra, community, ...), each its own jj repo. norn pulls the
// super-project, reads its ports.toml registry, and syncs every enabled
// subproject to its recorded pin. Sync refreshes manifests only; it never
// touches installed packages.
//
// Memory conventions: data structures (Subproject, enabled map) own their
// strings and come with free_* releasers. Error strings are borrowed —
// built with fmt.tprintf (temporary allocator) or literals — and must
// NEVER be passed to delete.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "norn:manifest"

// SYNC_CONFIG_PATH is the norn configuration file sync reads.
SYNC_CONFIG_PATH :: "/etc/norn/config.toml"

// SYNC_PIN_PATH records the super-project pin. It lives alongside the
// config (host-side, never under --sysroot) — NOT inside /usr/ports:
// jj deletes untracked files like /usr/ports/.pin on `jj new`.
SYNC_PIN_PATH :: "/etc/norn/ports.pin"

// Subproject is one entry of the super-project's ports.toml registry.
Subproject :: struct {
    name: string, // "core", "extra", ...
    url:  string, // jj repo URL
    pin:  string, // tag/commit to check out; "" tracks trunk
}

// Sync_Opts carries everything sync_tree needs. The string fields are
// borrowed, not owned: sync_tree never frees them.
Sync_Opts :: struct {
    ports_root:  string, // "/usr/ports"
    config_path: string, // "/etc/norn/config.toml"
    pin_path:    string, // "/etc/norn/ports.pin" (host-side, never in the jj tree)
    jj_bin:      string, // "jj" (a fake in tests)
    pin:         string, // "--pin TAG"
    unpin:       bool,   // "--unpin"
}

// free_subprojects releases a parse_ports_registry result: the cloned
// strings and the dynamic array itself.
free_subprojects :: proc(subs: [dynamic]Subproject) {
    for s in subs {
        delete(s.name)
        delete(s.url)
        delete(s.pin)
    }
    delete(subs)
}

// less_name orders subproject names: "core" first, then alphabetical.
less_name :: proc(a, b: string) -> bool {
    if a == "core" {
        return true
    }
    if b == "core" {
        return false
    }
    return a < b
}

// sort_names sorts in place: "core" first, then alphabetical.
sort_names :: proc(names: []string) {
    for i := 1; i < len(names); i += 1 {
        for j := i; j > 0 && less_name(names[j], names[j-1]); j -= 1 {
            names[j], names[j-1] = names[j-1], names[j]
        }
    }
}

// parse_ports_registry parses a ports.toml registry. Names come back in a
// deterministic order: "core" first, then alphabetical. Every returned
// string is owned by the caller; free with free_subprojects.
parse_ports_registry :: proc(data: string) -> (subs: [dynamic]Subproject, err: string) {
    doc, perr := manifest.parse_toml(data)
    defer manifest.toml_doc_destroy(&doc)
    if perr.msg != "" {
        return nil, fmt.tprintf("ports.toml:%d: %s", perr.line, perr.msg)
    }

    // Collect the distinct subproject names. These slices borrow from the
    // document and are only used below, before the deferred destroy runs.
    names := make([dynamic]string)
    defer delete(names)
    for k in doc.values {
        if !strings.has_prefix(k, "subprojects.") {
            continue
        }
        rest := k[len("subprojects."):]
        dot := strings.index_byte(rest, '.')
        if dot < 0 {
            continue
        }
        name := rest[:dot]
        seen := false
        for n in names {
            if n == name {
                seen = true
                break
            }
        }
        if !seen {
            append(&names, name)
        }
    }
    sort_names(names[:])

    out := make([dynamic]Subproject)
    for name in names {
        // aprintf, not tprintf: these keys are deleted below, and tprintf
        // uses the temporary allocator which must never be freed by hand.
        url_key := fmt.aprintf("subprojects.%s.url", name)
        pin_key := fmt.aprintf("subprojects.%s.pin", name)
        url_v, uok := doc.values[url_key]
        pin_v, pok := doc.values[pin_key]
        url_s, uok2 := url_v.(string)
        if !uok || !uok2 {
            err = fmt.tprintf("ports.toml: subproject '%s' needs a 'url' string", name)
        }
        pin_s := ""
        if err == "" && pok {
            if ps, is_str := pin_v.(string); is_str {
                pin_s = ps
            } else {
                err = fmt.tprintf("ports.toml: subproject '%s' 'pin' must be a string", name)
            }
        }
        delete(url_key)
        delete(pin_key)
        if err != "" {
            free_subprojects(out)
            return nil, err
        }
        append(&out, Subproject{strings.clone(name), strings.clone(url_s), strings.clone(pin_s)})
    }
    return out, ""
}

// free_sync_config releases a load_sync_config result.
free_sync_config :: proc(super_url: string, enabled: map[string]bool) {
    delete(super_url)
    for k in enabled {
        delete(k)
    }
    delete(enabled)
}

// load_sync_config reads the norn config file. Returns the super-project
// URL and the [repos.enabled] map. Keys are owned by the caller; free with
// free_sync_config. A missing file is an error with a starter example.
load_sync_config :: proc(path: string) -> (super_url: string, enabled: map[string]bool, err: string) {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return "", nil, fmt.tprintf(
            "cannot read %s: %v\nnorn sync needs a config file; minimal example:\n\n[repos]\nurl = \"https://packages.example.org/manifests/ports\"\n\n[repos.enabled]\ncore = true\nextra = true\n",
            path, rerr)
    }
    defer delete(data)

    doc, perr := manifest.parse_toml(string(data))
    defer manifest.toml_doc_destroy(&doc)
    if perr.msg != "" {
        return "", nil, fmt.tprintf("%s:%d: %s", path, perr.line, perr.msg)
    }

    url_v, found := doc.values["repos.url"]
    url_s, is_str := url_v.(string)
    if !found || !is_str {
        return "", nil, fmt.tprintf("%s: missing required key 'repos.url' (a string)", path)
    }
    super_url = strings.clone(url_s)

    enabled = make(map[string]bool)
    for k, v in doc.values {
        if !strings.has_prefix(k, "repos.enabled.") {
            continue
        }
        name := k[len("repos.enabled."):]
        b, is_bool := v.(bool)
        if !is_bool {
            free_sync_config(super_url, enabled)
            return "", nil, fmt.tprintf("%s: 'repos.enabled.%s' must be a boolean", path, name)
        }
        enabled[strings.clone(name)] = b
    }
    return super_url, enabled, ""
}

// compute_sync_plan filters the registry to the subprojects to sync. Core
// is mandatory: an explicit core = false is an error, and a registry
// without core is an error. Everything else follows [repos.enabled]
// (absent means disabled). The returned plan shares its strings with subs:
// delete() the plan array; free the strings with free_subprojects(subs).
compute_sync_plan :: proc(subs: []Subproject, enabled: map[string]bool) -> (plan: [dynamic]Subproject, err: string) {
    if v, ok := enabled["core"]; ok && !v {
        return nil, "the 'core' subproject is mandatory and cannot be disabled"
    }
    has_core := false
    for s in subs {
        if s.name == "core" {
            has_core = true
            break
        }
    }
    if !has_core {
        return nil, "the registry has no 'core' subproject"
    }
    out := make([dynamic]Subproject)
    for s in subs {
        if s.name == "core" || enabled[s.name] {
            append(&out, s)
        }
    }
    return out, ""
}

// run_jj executes jj with args in dir. Returns "" on success.
run_jj :: proc(jj_bin, dir: string, args: []string) -> string {
    cmd := make([dynamic]string, 0, len(args)+1)
    defer delete(cmd)
    append(&cmd, jj_bin)
    append_elems(&cmd, ..args)

    state, out, err_out, perr := os.process_exec(
        os.Process_Desc{working_dir = dir, command = cmd[:]},
        context.allocator,
    )
    defer delete(out)
    defer delete(err_out)
    if perr != nil {
        return fmt.tprintf("cannot execute '%s': %v", jj_bin, perr)
    }
    if !state.exited || state.exit_code != 0 {
        detail := strings.trim_space(string(err_out))
        if detail == "" {
            detail = strings.trim_space(string(out))
        }
        return fmt.tprintf("jj: exit %d: %s", state.exit_code, detail)
    }
    return ""
}

// clone_repo clones url into dir unless dir is already a jj repo.
// An existing non-repo dir is an error; an existing repo is a no-op.
clone_repo :: proc(jj_bin, dir, url: string) -> string {
    jj_dir, _ := filepath.join([]string{dir, ".jj"})
    defer delete(jj_dir)
    if os.exists(jj_dir) {
        return ""
    }
    if os.exists(dir) {
        return fmt.tprintf("%s exists but is not a jj repository", dir)
    }
    return run_jj(jj_bin, filepath.dir(dir), []string{"git", "clone", url, dir})
}

// fetch_repo pulls latest from the repo's remotes.
fetch_repo :: proc(jj_bin, dir: string) -> string {
    return run_jj(jj_bin, dir, []string{"git", "fetch"})
}

// checkout_rev moves the working copy to rev (a tag, commit, or revset).
checkout_rev :: proc(jj_bin, dir, rev: string) -> string {
    return run_jj(jj_bin, dir, []string{"new", rev})
}

// read_pin_file reads the pin dotfile. Returns the tag, or "" when there is
// no pin (file missing or blank).
read_pin_file :: proc(path: string) -> (pin: string, err: string) {
    if !os.exists(path) {
        return "", ""
    }
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return "", fmt.tprintf("cannot read %s: %v", path, rerr)
    }
    defer delete(data)
    trimmed := strings.trim_space(string(data))
    if trimmed == "" {
        return "", ""
    }
    return strings.clone(trimmed), ""
}

// sync_one_subproject clones/fetches a subproject and checks out its pin.
// With an empty pin the subproject tracks trunk. When the tree is pinned,
// nothing is fetched: the pin commit is already local.
sync_one_subproject :: proc(opts: ^Sync_Opts, dir: string, s: Subproject, pinned: string) -> string {
    if e := clone_repo(opts.jj_bin, dir, s.url); e != "" {
        return fmt.tprintf("subproject '%s': %s", s.name, e)
    }
    rev := s.pin
    if rev == "" {
        rev = "trunk()"
    }
    if pinned == "" {
        if e := fetch_repo(opts.jj_bin, dir); e != "" {
            return fmt.tprintf("subproject '%s': %s", s.name, e)
        }
    }
    if e := checkout_rev(opts.jj_bin, dir, rev); e != "" {
        return fmt.tprintf("subproject '%s': %s", s.name, e)
    }
    if s.pin != "" {
        fmt.printf("norn sync: subproject '%s' at '%s'\n", s.name, s.pin)
    } else {
        fmt.printf("norn sync: subproject '%s' tracking HEAD\n", s.name)
    }
    return ""
}

// sync_tree performs the full sync: super-project, then every subproject in
// the plan. Returns "" on success.
sync_tree :: proc(opts: ^Sync_Opts) -> string {
    super_url, enabled, err := load_sync_config(opts.config_path)
    if err != "" {
        return err
    }
    defer free_sync_config(super_url, enabled)

    pin_file := strings.clone(opts.pin_path)
    defer delete(pin_file)

    if opts.unpin {
        if os.exists(pin_file) {
            if rerr := os.remove(pin_file); rerr != nil {
                return fmt.tprintf("cannot remove %s: %v", pin_file, rerr)
            }
        }
        fmt.println("norn sync: unpinned; tracking HEAD")
    }

    if opts.pin != "" {
        // Pinning: fetch so the tag exists locally, check it out, record it.
        if e := clone_repo(opts.jj_bin, opts.ports_root, super_url); e != "" {
            return e
        }
        if e := fetch_repo(opts.jj_bin, opts.ports_root); e != "" {
            return e
        }
        if e := checkout_rev(opts.jj_bin, opts.ports_root, opts.pin); e != "" {
            return fmt.tprintf("cannot pin super-project at '%s': %s", opts.pin, e)
        }
        // The pin lives outside the jj tree (jj deletes untracked dotfiles
        // on `jj new`); ensure its directory exists.
        pin_dir := filepath.dir(pin_file)
        if !os.exists(pin_dir) {
            if derr := os.make_directory(pin_dir); derr != nil {
                return fmt.tprintf("cannot create %s: %v", pin_dir, derr)
            }
        }
        if werr := os.write_entire_file(pin_file, opts.pin); werr != nil {
            return fmt.tprintf("cannot write %s: %v", pin_file, werr)
        }
        fmt.printf("norn sync: pinned tree at '%s'\n", opts.pin)
    }

    pinned, rerr := read_pin_file(pin_file)
    if rerr != "" {
        return rerr
    }
    defer delete(pinned)

    // Super-project: track trunk, or hold the pin (no fetch when pinned).
    if e := clone_repo(opts.jj_bin, opts.ports_root, super_url); e != "" {
        return e
    }
    if pinned == "" {
        if e := fetch_repo(opts.jj_bin, opts.ports_root); e != "" {
            return e
        }
        if e := checkout_rev(opts.jj_bin, opts.ports_root, "trunk()"); e != "" {
            return e
        }
        fmt.println("norn sync: super-project tracking HEAD")
    } else {
        if e := checkout_rev(opts.jj_bin, opts.ports_root, pinned); e != "" {
            return e
        }
        fmt.printf("norn sync: super-project pinned at '%s'\n", pinned)
    }

    reg_path, _ := filepath.join([]string{opts.ports_root, "ports.toml"})
    defer delete(reg_path)
    reg_data, derr := os.read_entire_file(reg_path, context.allocator)
    if derr != nil {
        return fmt.tprintf("cannot read %s: %v", reg_path, derr)
    }
    defer delete(reg_data)

    subs, perr := parse_ports_registry(string(reg_data))
    if perr != "" {
        return perr
    }
    defer free_subprojects(subs)

    plan, plan_err := compute_sync_plan(subs[:], enabled)
    if plan_err != "" {
        return plan_err
    }
    defer delete(plan)

    for s in plan {
        dir, _ := filepath.join([]string{opts.ports_root, s.name})
        serr := sync_one_subproject(opts, dir, s, pinned)
        delete(dir)
        if serr != "" {
            return serr
        }
    }

    fmt.println("norn sync: tree is up to date")
    return ""
}
