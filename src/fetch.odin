// norn fetch: download and verify package sources.
//
// Three tiers, selected by fetch_mode from /etc/norn/config.toml:
//   "source" → VCS tier: clone via jj (git) or fossil, checkout the
//              manifest's branch (or HEAD), falling back to the
//              last-known-good tag+hash inside the tier if that fails.
//   "stable" → tarball tier: download the URL, sha256-verified.
//   "binary" → binary tier: download the .pkg.tar.zst, sha256-verified.
//
// The fetched source lands in work_dir/<name>/; the caller owns the
// returned path. Verification failures are hard errors: a bad hash
// deletes the downloaded file.
//
// Memory conventions: the returned dir string is heap-owned (delete it).
// Error strings are borrowed (tprintf temp / literals), never deleted.
package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "norn:manifest"

// Fetch_Opts configures source fetching. Tool binaries are looked up by
// name so tests can substitute fakes.
Fetch_Opts :: struct {
    work_dir:   string, // parent dir for fetched sources; "<work_dir>/<name>/"
    jj_bin:     string, // "jj" (git VCS)
    fossil_bin: string, // "fossil"
    fetch_bin:  string, // "curl" (core fetch utility in production)
}

// fetch_source fetches the package's source per fetch_mode and returns the
// directory holding it. fetch_mode is "source", "stable", or "binary".
fetch_source :: proc(m: ^manifest.Manifest, fetch_mode: string, opts: ^Fetch_Opts) -> (dir: string, err: string) {
    name := m.pkg.name
    if name == "" {
        return "", "fetch: manifest has no package name"
    }
    dest, _ := filepath.join([]string{opts.work_dir, name})
    defer delete(dest)

    switch fetch_mode {
    case "source":
        if !m.repo.present {
            return "", fmt.tprintf("fetch: package '%s' has no [source.repo] tier", name)
        }
        if e := fetch_vcs(m, dest, opts); e != "" {
            return "", e
        }
    case "stable":
        if !m.tarball.present {
            return "", fmt.tprintf("fetch: package '%s' has no [source.tarball] tier", name)
        }
        if e := fetch_url_file(m.tarball.url, m.tarball.sha256, dest, opts); e != "" {
            return "", e
        }
    case "binary":
        if !m.binary.present {
            return "", fmt.tprintf("fetch: package '%s' has no [source.binary] tier", name)
        }
        if e := fetch_url_file(m.binary.url, m.binary.sha256, dest, opts); e != "" {
            return "", e
        }
    case:
        return "", fmt.tprintf("fetch: unknown fetch_mode '%s' (want source|stable|binary)", fetch_mode)
    }
    return strings.clone(dest), ""
}

// fetch_vcs clones the repo tier via jj (git) or fossil and checks out the
// manifest's branch (or HEAD). On failure it falls back to last_known_tag
// inside the tier, verifying last_known_hash when the manifest records one.
fetch_vcs :: proc(m: ^manifest.Manifest, dest: string, opts: ^Fetch_Opts) -> string {
    if os.exists(dest) {
        return fmt.tprintf("fetch: '%s' already exists", dest)
    }
    switch m.repo.vcs {
    case "git":
        return fetch_git(m, dest, opts)
    case "fossil":
        return fetch_fossil(m, dest, opts)
    case:
        return fmt.tprintf("fetch: unsupported VCS '%s'", m.repo.vcs)
    }
}

// fetch_git clones with jj and resolves the checkout revision: the
// manifest's branch first, then HEAD, then the last-known-good tag.
fetch_git :: proc(m: ^manifest.Manifest, dest: string, opts: ^Fetch_Opts) -> string {
    if e := run_cmd(opts.jj_bin, filepath.dir(dest), []string{"git", "clone", m.repo.url, dest}); e != "" {
        return fmt.tprintf("fetch: clone failed: %s", e)
    }
    // Candidate revisions, best first.
    revs := make([dynamic]string)
    defer delete(revs)
    if m.repo.branch != "" {
        append(&revs, fmt.tprintf("%s@origin", m.repo.branch))
    } else {
        append(&revs, "trunk()")
    }
    have_fallback := m.repo.last_known_tag != ""
    if have_fallback {
        append(&revs, m.repo.last_known_tag)
    }
    last_err: string
    for rev in revs {
        if e := run_cmd(opts.jj_bin, dest, []string{"new", rev}); e == "" {
            // When we fell back to the tag, verify the recorded hash.
            if have_fallback && rev == m.repo.last_known_tag && m.repo.last_known_hash != "" {
                if ve := verify_jj_hash(opts.jj_bin, dest, m.repo.last_known_hash); ve != "" {
                    return ve
                }
            }
            return ""
        } else {
            last_err = e
        }
    }
    if have_fallback {
        return fmt.tprintf("fetch: branch/HEAD and fallback tag '%s' both failed: %s", m.repo.last_known_tag, last_err)
    }
    return fmt.tprintf("fetch: checkout failed: %s", last_err)
}

// verify_jj_hash checks that the working copy's commit id starts with the
// recorded hash (prefix match; manifests record the full hash).
verify_jj_hash :: proc(jj_bin, dir, want_hash: string) -> string {
    out, e := run_cmd_capture(jj_bin, dir, []string{"log", "-r", "@", "--template", "{commit_id}"})
    defer delete(out)
    if e != "" {
        return fmt.tprintf("fetch: cannot read commit id: %s", e)
    }
    got := strings.trim_space(out)
    if !strings.has_prefix(got, want_hash) && !strings.has_prefix(want_hash, got) {
        return fmt.tprintf("fetch: hash mismatch: got %s, want %s", got, want_hash)
    }
    return ""
}

// fetch_fossil clones and opens a fossil repo: the manifest's branch (or
// trunk), falling back to last_known_tag inside the tier.
fetch_fossil :: proc(m: ^manifest.Manifest, dest: string, opts: ^Fetch_Opts) -> string {
    // tprintf temp; do NOT delete.
    fossil_file := fmt.tprintf("%s.fossil", dest)
    if e := run_cmd(opts.fossil_bin, filepath.dir(dest), []string{"clone", m.repo.url, fossil_file}); e != "" {
        return fmt.tprintf("fetch: fossil clone failed: %s", e)
    }
    rev := m.repo.branch
    if rev == "" {
        rev = "trunk"
    }
    open := proc(bin, dir, fossil_file, rev, dest: string) -> string {
        return run_cmd(bin, dir, []string{"open", fossil_file, rev, "--workdir", dest})
    }
    if e := open(opts.fossil_bin, filepath.dir(dest), fossil_file, rev, dest); e != "" {
        if m.repo.last_known_tag == "" {
            return fmt.tprintf("fetch: fossil open failed: %s", e)
        }
        if e2 := open(opts.fossil_bin, filepath.dir(dest), fossil_file, m.repo.last_known_tag, dest); e2 != "" {
            return fmt.tprintf("fetch: fossil open failed (primary and fallback): %s", e2)
        }
    }
    return ""
}

// fetch_url_file downloads url to dest/<basename> and verifies its sha256.
// A hash mismatch deletes the file and is a hard error.
fetch_url_file :: proc(url, want_sha256, dest: string, opts: ^Fetch_Opts) -> string {
    if !os.exists(dest) {
        if merr := os.make_directory(dest); merr != nil {
            return fmt.tprintf("fetch: cannot create '%s': %v", dest, merr)
        }
    }
    base := filepath.base(url)
    // Strip query strings: "file-1.0.tar.gz?dl=1" -> "file-1.0.tar.gz".
    if q := strings.index_byte(base, '?'); q >= 0 {
        base = base[:q]
    }
    if base == "" || base == "." {
        base = "download"
    }
    out_path, _ := filepath.join([]string{dest, base})
    defer delete(out_path)
    if e := run_cmd(opts.fetch_bin, dest, []string{"-L", "-o", out_path, url}); e != "" {
        return fmt.tprintf("fetch: download failed: %s", e)
    }
    if e := verify_sha256(out_path, want_sha256); e != "" {
        os.remove(out_path)
        return e
    }
    return ""
}

// verify_sha256 checks the file's SHA-256 against the expected hex digest.
verify_sha256 :: proc(path, want_hex: string) -> string {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return fmt.tprintf("fetch: cannot read '%s': %v", path, rerr)
    }
    defer delete(data)
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, data)
    hash: [32]u8
    sha2.final(&ctx, hash[:])
    got := string(hex.encode(hash[:], context.temp_allocator))
    if !strings.equal_fold(got, want_hex) {
        return fmt.tprintf("fetch: sha256 mismatch for '%s'", path)
    }
    return ""
}

// load_fetch_mode reads the top-level `fetch_mode` key from the norn config.
// Returns "source" if unset. The returned string is owned; delete it.
load_fetch_mode :: proc(path: string) -> (mode: string, err: string) {
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return "", fmt.tprintf("cannot read %s: %v", path, rerr)
    }
    defer delete(data)

    doc, perr := manifest.parse_toml(string(data))
    defer manifest.toml_doc_destroy(&doc)
    if perr.msg != "" {
        return "", fmt.tprintf("%s:%d: %s", path, perr.line, perr.msg)
    }

    v, found := doc.values["fetch_mode"]
    if !found {
        return strings.clone("source"), ""
    }
    s, is_str := v.(string)
    if !is_str {
        return "", fmt.tprintf("%s: 'fetch_mode' must be a string", path)
    }
    switch s {
    case "source", "stable", "binary":
        return strings.clone(s), ""
    case:
        return "", fmt.tprintf("%s: unknown fetch_mode '%s' (want source|stable|binary)", path, s)
    }
}

// run_cmd executes a tool and returns "" on success, else a detail string.
run_cmd :: proc(bin, dir: string, args: []string) -> string {
    cmd := make([dynamic]string, 0, len(args)+1)
    defer delete(cmd)
    append(&cmd, bin)
    append_elems(&cmd, ..args)
    state, out, err_out, perr := os.process_exec(
        os.Process_Desc{working_dir = dir, command = cmd[:]},
        context.allocator,
    )
    defer delete(out)
    defer delete(err_out)
    if perr != nil {
        return fmt.tprintf("cannot execute '%s': %v", bin, perr)
    }
    if !state.exited || state.exit_code != 0 {
        detail := strings.trim_space(string(err_out))
        if detail == "" {
            detail = strings.trim_space(string(out))
        }
        return fmt.tprintf("'%s': exit %d: %s", bin, state.exit_code, detail)
    }
    return ""
}

// run_cmd_capture executes a tool and returns its stdout on success.
run_cmd_capture :: proc(bin, dir: string, args: []string) -> (out: string, err: string) {
    cmd := make([dynamic]string, 0, len(args)+1)
    defer delete(cmd)
    append(&cmd, bin)
    append_elems(&cmd, ..args)
    state, raw_out, err_out, perr := os.process_exec(
        os.Process_Desc{working_dir = dir, command = cmd[:]},
        context.allocator,
    )
    defer delete(err_out)
    if perr != nil {
        delete(raw_out)
        return "", fmt.tprintf("cannot execute '%s': %v", bin, perr)
    }
    if !state.exited || state.exit_code != 0 {
        detail := strings.trim_space(string(err_out))
        delete(raw_out)
        return "", fmt.tprintf("'%s': exit %d: %s", bin, state.exit_code, detail)
    }
    return string(raw_out), ""
}
