#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Unique temp base per test. Each test passes its own tag: the runner
// uses multiple threads, so a single shared dir races.
sync_test_base :: proc(tag: string) -> string {
    // aprintf, not tprintf: the caller deletes the result, and tprintf's
    // temporary allocator must never be freed by hand.
    return fmt.aprintf("/tmp/norn-sync-test-%d-%s", os.get_pid(), tag)
}

// joinp joins path parts in tests; join cannot realistically fail here.
joinp :: proc(t: ^testing.T, parts: []string) -> string {
    s, aerr := filepath.join(parts, context.allocator)
    if aerr != .None {
        testing.expectf(t, false, "filepath.join failed: %v", aerr)
        return ""
    }
    return s
}

@(test)
test_sync_parse_registry :: proc(t: ^testing.T) {
    data := `
[subprojects.core]
url = "https://example.org/core"
pin = "v1.0"

[subprojects.extra]
url = "https://example.org/extra"

[subprojects.community]
url = "https://example.org/community"
pin = "v2.0"
`
    subs, err := parse_ports_registry(data)
    defer free_subprojects(subs)
    // NOTE: error strings are borrowed (tprintf temp / literals), never deleted.
    testing.expectf(t, err == "", "parse failed: %s", err)
    if err != "" {
        return
    }
    testing.expect_value(t, len(subs), 3)
    // Deterministic order: core first, then alphabetical.
    testing.expect_value(t, subs[0].name, "core")
    testing.expect_value(t, subs[0].url, "https://example.org/core")
    testing.expect_value(t, subs[0].pin, "v1.0")
    testing.expect_value(t, subs[1].name, "community")
    testing.expect_value(t, subs[2].name, "extra")
    testing.expect_value(t, subs[2].pin, "")

    // A subproject without a url is an error.
    _, err2 := parse_ports_registry("[subprojects.broken]\npin = \"v1\"\n")
    testing.expect(t, err2 != "", "missing url should be an error")
}

@(test)
test_sync_compute_plan :: proc(t: ^testing.T) {
    // Owned strings: literals live in static storage and must not be freed.
    // Built as a dynamic array so free_subprojects can release the backing.
    subs := [dynamic]Subproject{
        {name = strings.clone("core"), url = strings.clone("https://example.org/core"), pin = strings.clone("v1.0")},
        {name = strings.clone("extra"), url = strings.clone("https://example.org/extra")},
    }
    defer free_subprojects(subs)

    enabled := make(map[string]bool)
    enabled[strings.clone("core")] = true
    enabled[strings.clone("extra")] = true
    defer free_enabled(enabled)
    plan, err := compute_sync_plan(subs[:], enabled)
    defer delete(plan)
    testing.expectf(t, err == "", "plan failed: %s", err)
    testing.expect_value(t, len(plan), 2)

    // Disabled stays out.
    enabled2 := make(map[string]bool)
    enabled2[strings.clone("core")] = true
    defer free_enabled(enabled2)
    plan2, err2 := compute_sync_plan(subs[:], enabled2)
    defer delete(plan2)
    testing.expectf(t, err2 == "", "plan failed: %s", err2)
    testing.expect_value(t, len(plan2), 1)
    testing.expect_value(t, plan2[0].name, "core")

    // core = false is an error.
    enabled3 := make(map[string]bool)
    enabled3[strings.clone("core")] = false
    defer free_enabled(enabled3)
    _, err3 := compute_sync_plan(subs[:], enabled3)
    testing.expect(t, err3 != "", "disabling core should be an error")
}

// free_enabled releases an enabled-map built in tests.
free_enabled :: proc(enabled: map[string]bool) {
    for k in enabled {
        delete(k)
    }
    delete(enabled)
}

@(test)
test_sync_load_config :: proc(t: ^testing.T) {
    base := sync_test_base("load_config")
    defer delete(base)
    defer os.remove_all(base)
    os.remove_all(base)
    if merr := os.make_directory(base); merr != nil {
        testing.expectf(t, false, "cannot create %s: %v", base, merr)
        return
    }

    cfg_path := joinp(t, []string{base, "norn.toml"})
    defer delete(cfg_path)
    cfg := "[repos]\nurl = \"https://example.org/ports\"\n\n[repos.enabled]\ncore = true\nextra = false\n"
    if werr := os.write_entire_file(cfg_path, cfg); werr != nil {
        testing.expectf(t, false, "cannot write config: %v", werr)
        return
    }

    url, enabled, err := load_sync_config(cfg_path)
    defer free_sync_config(url, enabled)
    testing.expectf(t, err == "", "load failed: %s", err)
    if err != "" {
        delete(err)
        return
    }
    testing.expect_value(t, url, "https://example.org/ports")
    testing.expect_value(t, enabled["core"], true)
    testing.expect_value(t, enabled["extra"], false)

    // Missing file is an error that points at the config.
    _, _, err2 := load_sync_config("/tmp/norn-sync-test-does-not-exist.toml")
    testing.expect(t, err2 != "", "missing config should be an error")
    testing.expect(t, strings.contains(err2, "config"), "error should mention the config file")
}

// Fake jj: logs invocations, simulates clone/fetch/new. Driven by env:
// FAKE_JJ_LOG receives "$@" per call; FAKE_JJ_REGISTRY (optional) is written
// as ports.toml into every cloned dir; `new <rev>` records the rev in
// ./jj-rev of the repo dir (the working directory).
FAKE_JJ_SCRIPT :: `#!/bin/sh
echo "$@" >> "$FAKE_JJ_LOG"
case "$1" in
  git)
    case "$2" in
      clone)
        mkdir -p "$4/.jj"
        if [ -n "$FAKE_JJ_REGISTRY" ]; then
          printf '%s' "$FAKE_JJ_REGISTRY" > "$4/ports.toml"
        fi
        ;;
    esac
    ;;
  new)
    echo "$2" > ./jj-rev
    ;;
esac
exit 0
`

write_fake_jj :: proc(t: ^testing.T, base: string) -> string {
    script_path := joinp(t, []string{base, "jj"})
    defer delete(script_path)
    if werr := os.write_entire_file(script_path, FAKE_JJ_SCRIPT); werr != nil {
        testing.expectf(t, false, "cannot write fake jj: %v", werr)
        return ""
    }
    // chmod +x via the real chmod: core:os has no chmod binding.
    state, out, errout, perr := os.process_exec(
        os.Process_Desc{command = []string{"/bin/chmod", "+x", script_path}},
        context.allocator,
    )
    defer delete(out)
    defer delete(errout)
    if perr != nil || !state.exited || state.exit_code != 0 {
        testing.expectf(t, false, "chmod failed: %v", perr)
        return ""
    }
    return strings.clone(script_path)
}

read_file_str :: proc(t: ^testing.T, path: string) -> string {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        testing.expectf(t, false, "cannot read %s: %v", path, rerr)
        return ""
    }
    defer delete(data)
    return strings.clone(strings.trim_space(string(data)))
}

@(test)
test_sync_tree_with_fake_jj :: proc(t: ^testing.T) {
    base := sync_test_base("tree")
    defer delete(base)
    defer os.remove_all(base)
    os.remove_all(base)
    if merr := os.make_directory(base); merr != nil {
        testing.expectf(t, false, "cannot create %s: %v", base, merr)
        return
    }

    fake_jj := write_fake_jj(t, base)
    defer delete(fake_jj)
    if fake_jj == "" {
        return
    }

    log_path := joinp(t, []string{base, "jj.log"})
    defer delete(log_path)
    registry := "[subprojects.core]\nurl = \"https://example.org/core\"\npin = \"v1.0\"\n\n[subprojects.extra]\nurl = \"https://example.org/extra\"\n"
    os.set_env("FAKE_JJ_LOG", log_path)
    defer os.unset_env("FAKE_JJ_LOG")
    os.set_env("FAKE_JJ_REGISTRY", registry)
    defer os.unset_env("FAKE_JJ_REGISTRY")

    cfg_path := joinp(t, []string{base, "norn.toml"})
    defer delete(cfg_path)
    cfg := "[repos]\nurl = \"https://example.org/ports\"\n\n[repos.enabled]\ncore = true\nextra = true\ncommunity = false\n"
    if werr := os.write_entire_file(cfg_path, cfg); werr != nil {
        testing.expectf(t, false, "cannot write config: %v", werr)
        return
    }

    ports_root := joinp(t, []string{base, "ports"})
    defer delete(ports_root)

    pin_path := joinp(t, []string{base, "ports.pin"})
    defer delete(pin_path)

    // Full sync: super-project cloned, subprojects at pins.
    opts := Sync_Opts{ports_root = ports_root, config_path = cfg_path, pin_path = pin_path, jj_bin = fake_jj}
    err := sync_tree(&opts)
    testing.expectf(t, err == "", "sync failed: %s", err)
    if err != "" {
        return
    }

    super_rev_path := joinp(t, []string{ports_root, "jj-rev"})
    defer delete(super_rev_path)
    super_rev := read_file_str(t, super_rev_path)
    defer delete(super_rev)
    testing.expect_value(t, super_rev, "trunk()")

    core_rev_path := joinp(t, []string{ports_root, "core", "jj-rev"})
    defer delete(core_rev_path)
    core_rev := read_file_str(t, core_rev_path)
    defer delete(core_rev)
    testing.expect_value(t, core_rev, "v1.0")

    extra_rev_path := joinp(t, []string{ports_root, "extra", "jj-rev"})
    defer delete(extra_rev_path)
    extra_rev := read_file_str(t, extra_rev_path)
    defer delete(extra_rev)
    testing.expect_value(t, extra_rev, "trunk()")

    // community is disabled: never cloned.
    community_path := joinp(t, []string{ports_root, "community"})
    defer delete(community_path)
    testing.expect(t, !os.exists(community_path), "disabled subproject must not sync")

    log := read_file_str(t, log_path)
    defer delete(log)
    testing.expect(t, strings.contains(log, "git fetch"), "sync should fetch")

    // Pin flow: --pin checks out the tag and records it.
    opts2 := Sync_Opts{ports_root = ports_root, config_path = cfg_path, pin_path = pin_path, jj_bin = fake_jj, pin = "v9.9"}
    err2 := sync_tree(&opts2)
    testing.expectf(t, err2 == "", "pin failed: %s", err2)
    pin_val := read_file_str(t, pin_path)
    defer delete(pin_val)
    testing.expect_value(t, pin_val, "v9.9")

    // Unpin flow: --unpin removes the record and tracks HEAD again.
    opts3 := Sync_Opts{ports_root = ports_root, config_path = cfg_path, pin_path = pin_path, jj_bin = fake_jj, unpin = true}
    err3 := sync_tree(&opts3)
    testing.expectf(t, err3 == "", "unpin failed: %s", err3)
    testing.expect(t, !os.exists(pin_path), "pin file should be gone after --unpin")
}
