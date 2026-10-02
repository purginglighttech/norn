// Tests for the fetch module: tier selection, sha256 verification, and the
// VCS fallback. All external tools (jj, curl) are faked with shell scripts.
package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "norn:manifest"

// test_work_dir creates a tagged temp dir for fetch tests.
test_work_dir :: proc(t: ^testing.T, tag: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir, _ := filepath.join([]string{base, fmt.tprintf("norn-fetch-%s-%d", tag, os.get_pid())})
    defer delete(dir)
    if merr := os.make_directory(dir); merr != nil {
        testing.fail_now(t)
    }
    // Caller owns; tests clean up explicitly.
    return strings.clone(dir)
}

// chmod_script makes a script executable via /bin/chmod (core:os has no chmod).
chmod_script :: proc(t: ^testing.T, path: string) {
    state, out, errout, perr := os.process_exec(
        os.Process_Desc{command = []string{"/bin/chmod", "+x", path}},
        context.allocator,
    )
    defer delete(out)
    defer delete(errout)
    if perr != nil || !state.exited || state.exit_code != 0 {
        testing.fail_now(t)
    }
}

// write_fake_fetch writes a shell script mimicking `curl -L -o <out> <url>`:
// it copies src_path to the -o target. The path is baked into the script
// (no env vars; tests run on multiple threads).
write_fake_fetch :: proc(t: ^testing.T, dir, src_path: string) -> string {
    path, _ := filepath.join([]string{dir, "fake-fetch"})
    script := fmt.tprintf("#!/bin/sh\n# fake curl: curl -L -o <out> <url>\nSRC=%s\nwhile [ $# -gt 0 ]; do\n  case \"$1\" in -o) out=\"$2\"; shift 2;; *) shift;; esac\ndone\ncp \"$SRC\" \"$out\"\n", src_path)
    // NB: script is tprintf temp memory; do NOT delete it.
    if werr := os.write_entire_file(path, script); werr != nil {
        testing.fail_now(t)
    }
    chmod_script(t, path)
    return path
}

sha256_of :: proc(t: ^testing.T, path: string) -> string {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        testing.fail_now(t)
    }
    defer delete(data)
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, data)
    hash: [32]u8
    sha2.final(&ctx, hash[:])
    enc := hex.encode(hash[:], context.allocator)
    defer delete(enc)
    return strings.clone(string(enc))
}

make_manifest :: proc(name: string) -> manifest.Manifest {
    return manifest.Manifest{
        pkg = manifest.Package_Info{name = strings.clone(name), version = strings.clone("1.0")},
    }
}

// set_repo assigns heap-owned repo tier strings (so manifest_destroy can free).
set_repo :: proc(m: ^manifest.Manifest, vcs, url, branch, tag, hash: string) {
    m.repo = manifest.Source_Repo{
        present         = true,
        vcs             = strings.clone(vcs),
        url             = strings.clone(url),
        branch          = strings.clone(branch),
        last_known_tag  = strings.clone(tag),
        last_known_hash = strings.clone(hash),
    }
}

// set_tarball assigns heap-owned tarball tier strings.
set_tarball :: proc(m: ^manifest.Manifest, url, sha256: string) {
    m.tarball = manifest.Source_Tarball{present = true, url = strings.clone(url), sha256 = strings.clone(sha256)}
}

@(test)
test_fetch_unknown_mode :: proc(t: ^testing.T) {
    m := make_manifest("foo")
    defer manifest_destroy(&m)
    opts := Fetch_Opts{work_dir = "/tmp", jj_bin = "jj", fossil_bin = "fossil", fetch_bin = "curl"}
    _, err := fetch_source(&m, "bogus", &opts)
    testing.expect(t, err != "", "unknown fetch_mode should fail")
}

@(test)
test_fetch_missing_tier :: proc(t: ^testing.T) {
    m := make_manifest("foo")
    defer manifest_destroy(&m)
    opts := Fetch_Opts{work_dir = "/tmp", jj_bin = "jj", fossil_bin = "fossil", fetch_bin = "curl"}
    _, err := fetch_source(&m, "stable", &opts)
    testing.expect(t, err != "", "missing tarball tier should fail")
    testing.expect(t, strings.contains(err, "tarball"), "error should name the tier")
}

@(test)
test_fetch_tarball_ok :: proc(t: ^testing.T) {
    work := test_work_dir(t, "tb-ok")
    defer delete(work)
    defer os.remove_all(work)

    // The "remote" file the fake fetch will copy.
    src_path, _ := filepath.join([]string{work, "payload.tar.gz"})
    defer delete(src_path)
    if werr := os.write_entire_file(src_path, "fake tarball bytes"); werr != nil {
        testing.fail_now(t)
    }
    want := sha256_of(t, src_path)
    defer delete(want)

    fake := write_fake_fetch(t, work, src_path)
    defer delete(fake)

    m := make_manifest("foo")
    defer manifest_destroy(&m)
    set_tarball(&m, "https://example.com/foo-1.0.tar.gz", want)

    opts := Fetch_Opts{work_dir = work, jj_bin = "jj", fossil_bin = "fossil", fetch_bin = fake}
    dir, err := fetch_source(&m, "stable", &opts)
    defer delete(dir)
    testing.expectf(t, err == "", "fetch should succeed, got: %s", err)
    if err != "" {
        return
    }
    got_path, _ := filepath.join([]string{dir, "foo-1.0.tar.gz"})
    defer delete(got_path)
    testing.expect(t, os.exists(got_path), "downloaded file should exist")
}

@(test)
test_fetch_tarball_bad_hash :: proc(t: ^testing.T) {
    work := test_work_dir(t, "tb-bad")
    defer delete(work)
    defer os.remove_all(work)

    src_path, _ := filepath.join([]string{work, "payload.tar.gz"})
    defer delete(src_path)
    if werr := os.write_entire_file(src_path, "fake tarball bytes"); werr != nil {
        testing.fail_now(t)
    }
    fake := write_fake_fetch(t, work, src_path)
    defer delete(fake)

    m := make_manifest("foo")
    defer manifest_destroy(&m)
    // Wrong hash on purpose.
    bad_hash := strings.repeat("0", 64, context.allocator)
    defer delete(bad_hash)
    set_tarball(&m, "https://example.com/foo-1.0.tar.gz", bad_hash)

    opts := Fetch_Opts{work_dir = work, jj_bin = "jj", fossil_bin = "fossil", fetch_bin = fake}
    dir, err := fetch_source(&m, "stable", &opts)
    defer delete(dir)
    testing.expect(t, err != "", "hash mismatch should fail")
    testing.expect(t, strings.contains(err, "sha256"), "error should mention sha256")
    // The bad file must be deleted.
    bad_path, _ := filepath.join([]string{work, "foo", "foo-1.0.tar.gz"})
    defer delete(bad_path)
    testing.expect(t, !os.exists(bad_path), "bad file should be removed")
}

@(test)
test_fetch_git_branch :: proc(t: ^testing.T) {
    // Fake jj: simulates `git clone` (creates dest/.jj) and `new <rev>`
    // (records the rev in ./jj-rev).
    work := test_work_dir(t, "git-branch")
    defer delete(work)
    defer os.remove_all(work)

    jj_path, _ := filepath.join([]string{work, "jj"})
    defer delete(jj_path)
    script := "#!/bin/sh\ncase \"$1\" in\n  git) mkdir -p \"$4/.jj\" ;;\n  new) echo \"$2\" > ./jj-rev ;;\nesac\nexit 0\n"
    if werr := os.write_entire_file(jj_path, script); werr != nil {
        testing.fail_now(t)
    }
    chmod_script(t, jj_path)

    m := make_manifest("foo")
    defer manifest_destroy(&m)
    set_repo(&m, "git", "https://example.com/foo.git", "main", "", "")

    opts := Fetch_Opts{work_dir = work, jj_bin = jj_path, fossil_bin = "fossil", fetch_bin = "curl"}
    dir, err := fetch_source(&m, "source", &opts)
    defer delete(dir)
    testing.expectf(t, err == "", "git fetch should succeed, got: %s", err)
    if err != "" {
        return
    }
    // The fake jj should have been asked to check out main@origin.
    rev_path, _ := filepath.join([]string{dir, "jj-rev"})
    defer delete(rev_path)
    data, rerr := os.read_entire_file(rev_path, context.allocator)
    defer delete(data)
    testing.expect(t, rerr == nil, "jj-rev should exist")
    if rerr == nil {
        testing.expect(t, strings.trim_space(string(data)) == "main@origin", "should check out branch@origin")
    }
}

@(test)
test_fetch_git_fallback_tag :: proc(t: ^testing.T) {
    // Fake jj: `new <branch>@origin` fails, `new <tag>` succeeds and reports
    // a fixed commit id for hash verification.
    work := test_work_dir(t, "git-fallback")
    defer delete(work)
    defer os.remove_all(work)

    jj_path, _ := filepath.join([]string{work, "jj"})
    defer delete(jj_path)
    script := "#!/bin/sh\ncase \"$1\" in\n  git) mkdir -p \"$4/.jj\" ;;\n  new)\n    if [ \"$2\" = \"main@origin\" ]; then exit 1; fi\n    echo \"$2\" > ./jj-rev ;;\n  log) printf 'abc123def456' ;;\nesac\nexit 0\n"
    if werr := os.write_entire_file(jj_path, script); werr != nil {
        testing.fail_now(t)
    }
    chmod_script(t, jj_path)

    m := make_manifest("foo")
    defer manifest_destroy(&m)
    set_repo(&m, "git", "https://example.com/foo.git", "main", "v1.0", "abc123")

    opts := Fetch_Opts{work_dir = work, jj_bin = jj_path, fossil_bin = "fossil", fetch_bin = "curl"}
    dir, err := fetch_source(&m, "source", &opts)
    defer delete(dir)
    testing.expectf(t, err == "", "fallback fetch should succeed, got: %s", err)
    if err != "" {
        return
    }
    rev_path, _ := filepath.join([]string{dir, "jj-rev"})
    defer delete(rev_path)
    data, rerr := os.read_entire_file(rev_path, context.allocator)
    defer delete(data)
    testing.expect(t, rerr == nil, "jj-rev should exist")
    if rerr == nil {
        testing.expect(t, strings.trim_space(string(data)) == "v1.0", "should fall back to the tag")
    }
}

// manifest_destroy frees owned manifest strings (test helper).
manifest_destroy :: proc(m: ^manifest.Manifest) {
    delete(m.pkg.name)
    delete(m.pkg.version)
    delete(m.repo.vcs)
    delete(m.repo.url)
    delete(m.repo.branch)
    delete(m.repo.last_known_tag)
    delete(m.repo.last_known_hash)
    delete(m.tarball.url)
    delete(m.tarball.sha256)
    delete(m.binary.url)
    delete(m.binary.sha256)
}

@(test)
test_load_fetch_mode :: proc(t: ^testing.T) {
    work := test_work_dir(t, "fetch-mode")
    defer delete(work)
    defer os.remove_all(work)

    cfg, _ := filepath.join([]string{work, "config.toml"})
    defer delete(cfg)

    // Explicit mode.
    if werr := os.write_entire_file(cfg, "fetch_mode = \"binary\"\n"); werr != nil {
        testing.fail_now(t)
    }
    mode, err := load_fetch_mode(cfg)
    defer delete(mode)
    testing.expect(t, err == "", "explicit mode should parse")
    testing.expect(t, mode == "binary", "should read 'binary'")

    // Unset → default "source".
    if werr := os.write_entire_file(cfg, "[repos]\nurl = \"x\"\n"); werr != nil {
        testing.fail_now(t)
    }
    mode2, err2 := load_fetch_mode(cfg)
    defer delete(mode2)
    testing.expect(t, err2 == "", "missing mode should not error")
    testing.expect(t, mode2 == "source", "missing mode defaults to 'source'")

    // Invalid mode → error.
    if werr := os.write_entire_file(cfg, "fetch_mode = \"bogus\"\n"); werr != nil {
        testing.fail_now(t)
    }
    _, err3 := load_fetch_mode(cfg)
    testing.expect(t, err3 != "", "invalid mode should fail")
}
