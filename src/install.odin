// norn install: the local database and lifecycle operations.
//
// DB root is <sysroot>/var/lib/norn/:
//   installed/<name>/manifest.toml  copy of the installed manifest
//   installed/<name>/info           version, release, priority, fetch tier, timestamp
//   installed/<name>/symlinks       live paths symlinked (one per line)
//   installed/<name>/configs        live config paths + sha256 (one per line)
//   installed/<name>/config_orig/   pristine config copies for 3-way merge
//   installed/<name>/pending        pending .new merges (one live path per line)
//   installed/<name>/tombstone      set on remove: configs left behind
//   world                           explicitly installed packages (one per line)
//   lock                            operation lock (file exists = locked)
//   registry                        priority registry: "<livepath> <pkg> <priority>"
//
// Install model (§8): each package lives in /usr/apps/<name>/<version>/;
// post-install symlinks prefix files into the live tree (/usr/bin, ...).
// Files under <prefix>/etc/ are COPIED (never symlinked); their hashes are
// recorded. When two packages ship the same live path, highest priority
// wins; ties are install-time errors.
//
// Memory: returned strings are owned unless noted. Error strings are
// borrowed, never deleted.
package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "norn:manifest"

// db_root returns <sysroot>/var/lib/norn (owned).
db_root :: proc(sysroot: string) -> string {
    if sysroot == "" || sysroot == "/" {
        return strings.clone("/var/lib/norn")
    }
    return fmt.aprintf("%s/var/lib/norn", strings.trim_suffix(sysroot, "/"))
}

// db_init creates the database directories.
db_init :: proc(sysroot: string) -> string {
    root := db_root(sysroot)
    defer delete(root)
    dirs := []string{"installed",}
    for d in dirs {
        p, _ := filepath.join([]string{root, d})
        defer delete(p)
        if merr := os.make_directory_all(p); merr != nil {
            return fmt.tprintf("db: cannot create '%s': %v", p, merr)
        }
    }
    return ""
}

// db_lock takes the operation lock. Alpha refuses concurrent runs outright.
db_lock :: proc(sysroot: string) -> string {
    root := db_root(sysroot)
    defer delete(root)
    lock, _ := filepath.join([]string{root, "lock"})
    defer delete(lock)
    if os.exists(lock) {
        return "db: another norn operation is running (lock exists)"
    }
    if werr := os.write_entire_file(lock, fmt.tprintf("%d", os.get_pid())); werr != nil {
        return fmt.tprintf("db: cannot create lock: %v", werr)
    }
    return ""
}

// db_unlock releases the operation lock.
db_unlock :: proc(sysroot: string) {
    root := db_root(sysroot)
    defer delete(root)
    lock, _ := filepath.join([]string{root, "lock"})
    defer delete(lock)
    os.remove(lock)
}

// installed_dir returns <db>/installed/<name> (owned).
installed_dir :: proc(sysroot, name: string) -> string {
    root := db_root(sysroot)
    defer delete(root)
    p, _ := filepath.join([]string{root, "installed", name})
    return p
}

// is_installed reports whether the package has a db entry.
is_installed :: proc(sysroot, name: string) -> bool {
    dir := installed_dir(sysroot, name)
    defer delete(dir)
    return os.exists(dir)
}

// Install_Opts configures install/remove/upgrade.
Install_Opts :: struct {
    sysroot: string, // "/" for live
}

// live_path maps a prefix-relative path to the live tree.
// <prefix>/bin/ls -> <sysroot>/usr/bin/ls
// <prefix>/etc/foo.conf -> <sysroot>/etc/foo.conf
// Returns (live, is_config, owned).
live_path :: proc(prefix_rel, sysroot: string) -> (live: string, is_config: bool, ok: bool) {
    // prefix_rel is like "bin/ls" or "etc/foo.conf".
    slash := strings.index_byte(prefix_rel, '/')
    if slash < 0 {
        return "", false, false
    }
    top := prefix_rel[:slash]
    rest := prefix_rel[slash:]
    base := sysroot
    if base == "" {
        base = "/"
    }
    if top == "etc" {
        // Config: /etc/... (copied, never symlinked).
        return fmt.aprintf("%s/etc%s", strings.trim_suffix(base, "/"), rest), true, true
    }
    // Everything else: /usr/<top>/...
    return fmt.aprintf("%s/usr/%s%s", strings.trim_suffix(base, "/"), top, rest), false, true
}

// Install_Walk_Ctx carries state for the prefix walk.
Install_Walk_Ctx :: struct {
    m:        ^manifest.Manifest,
    prefix:   string,
    opts:     ^Install_Opts,
    symlinks: ^[dynamic]string,
    configs:  ^[dynamic]string,
}

install_walk_fn :: proc(rel: string, ctx: ^Install_Walk_Ctx) -> string {
    live, is_config, ok := live_path(rel, ctx.opts.sysroot)
    defer delete(live)
    if !ok {
        return fmt.tprintf("install: cannot map prefix path '%s'", rel)
    }
    src, _ := filepath.join([]string{ctx.prefix, rel})
    defer delete(src)
    if is_config {
        return install_config(src, live, ctx.configs)
    }
    return install_symlink(src, live, ctx.m.pkg.name, ctx.m.pkg.priority, ctx.opts.sysroot, ctx.symlinks)
}

// install_package runs the post-install pass: symlinks, config copies,
// priority registry, db record. The prefix must already hold the built
// (or extracted) package tree.
install_package :: proc(m: ^manifest.Manifest, prefix: string, opts: ^Install_Opts) -> string {
    name := m.pkg.name
    if is_installed(opts.sysroot, name) {
        return fmt.tprintf("install: '%s' is already installed", name)
    }

    // Walk the prefix.
    symlinks := make([dynamic]string)
    defer {
        for s in symlinks {
            delete(s)
        }
        delete(symlinks)
    }
    configs := make([dynamic]string) // "livepath sha256"
    defer {
        for s in configs {
            delete(s)
        }
        delete(configs)
    }

    ctx := Install_Walk_Ctx{m = m, prefix = prefix, opts = opts, symlinks = &symlinks, configs = &configs}
    if err := walk_prefix(prefix, install_walk_fn, &ctx); err != "" {
        return err
    }

    // Record in the db.
    if e := db_record_install(opts.sysroot, m, prefix, symlinks[:], configs[:]); e != "" {
        return e
    }
    if e := world_add(opts.sysroot, name); e != "" {
        return e
    }
    return ""
}

// walk_prefix calls fn for every file under prefix (relative paths).
// Directories themselves are not passed; parent dirs of live paths are
// created as needed.
walk_prefix :: proc(prefix: string, fn: proc(rel: string, ctx: ^Install_Walk_Ctx) -> string, ctx: ^Install_Walk_Ctx) -> string {
    return walk_prefix_rec(prefix, "", fn, ctx)
}

walk_prefix_rec :: proc(prefix, rel: string, fn: proc(rel: string, ctx: ^Install_Walk_Ctx) -> string, ctx: ^Install_Walk_Ctx) -> string {
    dir := prefix
    if rel != "" {
        dir, _ = filepath.join([]string{prefix, rel})
        defer delete(dir)
    }
    f, oerr := os.open(dir)
    if oerr != nil {
        return fmt.tprintf("install: cannot open '%s': %v", dir, oerr)
    }
    defer os.close(f)
    entries, rerr := os.read_directory(f, 0, context.allocator)
    if rerr != nil {
        return fmt.tprintf("install: cannot read '%s': %v", dir, rerr)
    }
    defer {
        for e in entries {
            os.file_info_delete(e, context.allocator)
        }
        delete(entries)
    }
    for e in entries {
        sub_rel := fmt.aprintf("%s%s%s", rel, "/" if rel != "" else "", e.name)
        defer delete(sub_rel)
        if e.type == .Directory {
            if err := walk_prefix_rec(prefix, sub_rel, fn, ctx); err != "" {
                return err
            }
        } else if e.type == .Regular {
            if err := fn(sub_rel, ctx); err != "" {
                return err
            }
        }
        // Symlinks etc. in the prefix are skipped in alpha.
    }
    return ""
}

// install_symlink creates the live symlink, applying the priority registry.
install_symlink :: proc(src, live, pkg: string, priority: i64, sysroot: string, symlinks: ^[dynamic]string) -> string {
    // Ensure parent dir (skip if it exists; mkdir_all errors on EEXIST).
    parent := filepath.dir(live)
    if !os.exists(parent) {
        if merr := os.make_directory_all(parent); merr != nil {
            return fmt.tprintf("install: cannot create '%s': %v", parent, merr)
        }
    }

    // Priority check: who owns this path?
    owner, owner_prio, found := registry_lookup(sysroot, live)
    defer delete(owner)
    if found {
        if owner == pkg {
            // Already ours (reinstall); skip.
            return ""
        }
        if priority > owner_prio {
            // We win; remove the loser's symlink (their db entry stays;
            // they lose the path until reinstall/upgrade).
            os.remove(live)
        } else if priority == owner_prio {
            return fmt.tprintf("install: '%s' and '%s' both ship '%s' with priority %d; set priority to resolve", owner, pkg, live, priority)
        } else {
            // We lose; skip this path.
            return ""
        }
    }

    if os.exists(live) {
        // A non-symlink file is in the way; don't clobber.
        return fmt.tprintf("install: '%s' exists and is not managed by norn", live)
    }
    if serr := os.symlink(src, live); serr != nil {
        return fmt.tprintf("install: cannot symlink '%s': %v", live, serr)
    }
    if e := registry_set(sysroot, live, pkg, priority); e != "" {
        return e
    }
    append(symlinks, strings.clone(live))
    return ""
}

// install_config copies a config file to the live path and records its hash.
install_config :: proc(src, live: string, configs: ^[dynamic]string) -> string {
    parent := filepath.dir(live)
    if !os.exists(parent) {
        if merr := os.make_directory_all(parent); merr != nil {
            return fmt.tprintf("install: cannot create '%s': %v", parent, merr)
        }
    }
    data, rerr := os.read_entire_file(src, context.allocator)
    if rerr != nil {
        return fmt.tprintf("install: cannot read '%s': %v", src, rerr)
    }
    defer delete(data)
    // If live exists, only overwrite if unmodified (checked by caller
    // via the db; here we just copy on fresh install).
    if !os.exists(live) {
        if werr := os.write_entire_file(live, data); werr != nil {
            return fmt.tprintf("install: cannot write '%s': %v", live, werr)
        }
    }
    hash := sha256_hex(data)
    defer delete(hash)
    append(configs, fmt.aprintf("%s %s", live, hash))
    // Pristine copy for 3-way merge lives in the db (db_record_install).
    return ""
}

// sha256_hex returns the hex SHA-256 of data (owned).
sha256_hex :: proc(data: []u8) -> string {
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, data)
    hash: [32]u8
    sha2.final(&ctx, hash[:])
    enc := hex.encode(hash[:], context.allocator)
    defer delete(enc)
    return strings.clone(string(enc))
}

// registry_path returns the registry file path (owned).
registry_path :: proc(sysroot: string) -> string {
    root := db_root(sysroot)
    defer delete(root)
    p, _ := filepath.join([]string{root, "registry"})
    return p
}

// registry_lookup finds the owner of a live path.
// Returns (owner, priority, found). Owner is owned.
registry_lookup :: proc(sysroot, live: string) -> (owner: string, priority: i64, found: bool) {
    path := registry_path(sysroot)
    defer delete(path)
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return "", 0, false
    }
    defer delete(data)
    _lines1 := strings.split_lines(string(data), context.allocator)
    defer delete(_lines1)
    for line in _lines1 {
        // Format: "<livepath> <pkg> <priority>"
        parts := strings.split(line, " ", context.temp_allocator)
        if len(parts) != 3 {
            continue
        }
        if parts[0] == live {
            prio, _ := strconv.parse_i64(parts[2])
            return strings.clone(parts[1]), prio, true
        }
    }
    return "", 0, false
}

// registry_set records (or updates) a live path owner.
registry_set :: proc(sysroot, live, pkg: string, priority: i64) -> string {
    path := registry_path(sysroot)
    defer delete(path)
    // Read existing, filter out this live path, append the new entry.
    lines := make([dynamic]string)
    defer {
        for l in lines {
            delete(l)
        }
        delete(lines)
    }
    if os.exists(path) {
        data, rerr := os.read_entire_file(path, context.allocator)
        if rerr == nil {
            defer delete(data)
            _lines2 := strings.split_lines(string(data), context.allocator)
            defer delete(_lines2)
            for line in _lines2 {
                t := strings.trim_space(line)
                if t == "" {
                    continue
                }
                // Keep lines for other paths.
                if !strings.has_prefix(t, live) || (len(t) > len(live) && t[len(live)] != ' ') {
                    append(&lines, strings.clone(t))
                }
            }
        }
    }
    append(&lines, fmt.aprintf("%s %s %d", live, pkg, priority))
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for l in lines {
        strings.write_string(&sb, l)
        strings.write_byte(&sb, '\n')
    }
    if werr := os.write_entire_file(path, strings.to_string(sb)); werr != nil {
        return fmt.tprintf("db: cannot write registry: %v", werr)
    }
    return ""
}

// registry_remove drops a live path from the registry.
registry_remove :: proc(sysroot, live: string) -> string {
    path := registry_path(sysroot)
    defer delete(path)
    if !os.exists(path) {
        return ""
    }
    data, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return ""
    }
    defer delete(data)
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    _l410 := strings.split_lines(string(data), context.allocator)
    defer delete(_l410)
    for line in _l410 {
        t := strings.trim_space(line)
        if t == "" {
            continue
        }
        if strings.has_prefix(t, live) && (len(t) == len(live) || t[len(live)] == ' ') {
            continue
        }
        strings.write_string(&sb, t)
        strings.write_byte(&sb, '\n')
    }
    if werr := os.write_entire_file(path, strings.to_string(sb)); werr != nil {
        return fmt.tprintf("db: cannot write registry: %v", werr)
    }
    return ""
}

// db_record_install writes the installed/<name>/ db entry.
db_record_install :: proc(sysroot: string, m: ^manifest.Manifest, prefix: string, symlinks, configs: []string) -> string {
    dir := installed_dir(sysroot, m.pkg.name)
    defer delete(dir)
    if merr := os.make_directory_all(dir); merr != nil {
        return fmt.tprintf("db: cannot create '%s': %v", dir, merr)
    }

    // info: version, release, priority, timestamp.
    info_path, _ := filepath.join([]string{dir, "info"})
    defer delete(info_path)
    info := fmt.tprintf("version=%s\nrelease=%d\npriority=%d\n", m.pkg.version, m.pkg.release, m.pkg.priority)
    // tprintf temp; write synchronously.
    if werr := os.write_entire_file(info_path, info); werr != nil {
        return fmt.tprintf("db: cannot write info: %v", werr)
    }

    // symlinks list.
    sl_path, _ := filepath.join([]string{dir, "symlinks"})
    defer delete(sl_path)
    {
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        for s in symlinks {
            strings.write_string(&sb, s)
            strings.write_byte(&sb, '\n')
        }
        if werr := os.write_entire_file(sl_path, strings.to_string(sb)); werr != nil {
            return fmt.tprintf("db: cannot write symlinks: %v", werr)
        }
    }

    // configs list + pristine copies.
    cfg_path, _ := filepath.join([]string{dir, "configs"})
    defer delete(cfg_path)
    orig_dir, _ := filepath.join([]string{dir, "config_orig"})
    defer delete(orig_dir)
    if merr := os.make_directory_all(orig_dir); merr != nil {
        return fmt.tprintf("db: cannot create '%s': %v", orig_dir, merr)
    }
    {
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        for c in configs {
            // c is "livepath hash".
            strings.write_string(&sb, c)
            strings.write_byte(&sb, '\n')
            // Pristine copy: <orig_dir>/<livepath with / -> _>.
            space := strings.index_byte(c, ' ')
            if space > 0 {
                live := c[:space]
                safe, was_alloc := strings.replace_all(live, "/", "_", context.allocator)
                if was_alloc {
                    defer delete(safe)
                }
                dest, _ := filepath.join([]string{orig_dir, safe})
                defer delete(dest)
                if data, rerr := os.read_entire_file(live, context.allocator); rerr == nil {
                    defer delete(data)
                    _ = os.write_entire_file(dest, data)
                }
            }
        }
        if werr := os.write_entire_file(cfg_path, strings.to_string(sb)); werr != nil {
            return fmt.tprintf("db: cannot write configs: %v", werr)
        }
    }
    return ""
}

// remove_package drops symlinks, deletes the prefix, and tombstones configs.
// Copied configs are LEFT in place; their paths are printed.
remove_package :: proc(sysroot, name: string, opts: ^Install_Opts) -> (left_configs: string, err: string) {
    if !is_installed(sysroot, name) {
        return "", fmt.tprintf("remove: '%s' is not installed", name)
    }
    dir := installed_dir(sysroot, name)
    defer delete(dir)

    // Drop symlinks.
    sl_path, _ := filepath.join([]string{dir, "symlinks"})
    defer delete(sl_path)
    if data, rerr := os.read_entire_file(sl_path, context.allocator); rerr == nil {
        defer delete(data)
        _l513 := strings.split_lines(string(data), context.allocator)
        defer delete(_l513)
        for line in _l513 {
            live := strings.trim_space(line)
            if live == "" {
                continue
            }
            os.remove(live)
            registry_remove(sysroot, live)
        }
    }

    // Delete the prefix. Find it via the info file (version).
    prefix := installed_prefix(sysroot, name)
    defer delete(prefix)
    if prefix != "" {
        os.remove_all(prefix)
    }

    // Configs: leave in place, write tombstone.
    cfg_path, _ := filepath.join([]string{dir, "configs"})
    defer delete(cfg_path)
    tomb_path, _ := filepath.join([]string{dir, "tombstone"})
    defer delete(tomb_path)
    left := make([dynamic]string)
    defer {
        for s in left {
            delete(s)
        }
        delete(left)
    }
    if data, rerr := os.read_entire_file(cfg_path, context.allocator); rerr == nil {
        defer delete(data)
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        _l547 := strings.split_lines(string(data), context.allocator)
        defer delete(_l547)
        for line in _l547 {
            t := strings.trim_space(line)
            if t == "" {
                continue
            }
            strings.write_string(&sb, t)
            strings.write_byte(&sb, '\n')
            space := strings.index_byte(t, ' ')
            if space > 0 {
                append(&left, strings.clone(t[:space]))
            }
        }
        _ = os.write_entire_file(tomb_path, strings.to_string(sb))
    }

    // Remove db entry except tombstone: delete everything but tombstone.
    // (Simplify: keep the dir with only tombstone.)
    db_files := [5]string{"manifest.toml", "info", "symlinks", "configs", "pending"}
    for entry in db_files {
        p, _ := filepath.join([]string{dir, entry})
        defer delete(p)
        os.remove(p)
    }
    orig_dir, _ := filepath.join([]string{dir, "config_orig"})
    defer delete(orig_dir)
    os.remove_all(orig_dir)

    // Return the left config paths for printing.
    out: strings.Builder
    strings.builder_init(&out)
    defer strings.builder_destroy(&out)
    for l in left {
        strings.write_string(&out, l)
        strings.write_byte(&out, '\n')
    }
    return strings.clone(strings.to_string(out)), ""
}

// installed_prefix reads the version from db info and returns the prefix.
installed_prefix :: proc(sysroot, name: string) -> string {
    dir := installed_dir(sysroot, name)
    defer delete(dir)
    info_path, _ := filepath.join([]string{dir, "info"})
    defer delete(info_path)
    data, rerr := os.read_entire_file(info_path, context.allocator)
    if rerr != nil {
        return ""
    }
    defer delete(data)
    version := ""
    _l597 := strings.split_lines(string(data), context.allocator)
    defer delete(_l597)
    for line in _l597 {
        if strings.has_prefix(line, "version=") {
            version = strings.trim_space(line[len("version="):])
        }
    }
    if version == "" {
        return ""
    }
    base := sysroot
    if base == "" {
        base = "/"
    }
    return fmt.aprintf("%s/usr/apps/%s/%s", strings.trim_suffix(base, "/"), name, version)
}

// purge_package removes the package AND its left-behind configs.
// Works on already-removed packages via the tombstone.
purge_package :: proc(sysroot, name: string, opts: ^Install_Opts) -> string {
    // If still installed, remove first (but keep the tombstone).
    if is_installed(sysroot, name) {
        dir := installed_dir(sysroot, name)
        defer delete(dir)
        tomb_path, _ := filepath.join([]string{dir, "tombstone"})
        defer delete(tomb_path)
        has_tombstone := os.exists(tomb_path)
        if _, err := remove_package(sysroot, name, opts); err != "" {
            return err
        }
        // remove_package leaves the tombstone; if it didn't exist before,
        // the dir now has only the tombstone (or nothing).
        _ = has_tombstone
    }
    dir := installed_dir(sysroot, name)
    defer delete(dir)
    tomb_path, _ := filepath.join([]string{dir, "tombstone"})
    defer delete(tomb_path)
    if os.exists(tomb_path) {
        if data, rerr := os.read_entire_file(tomb_path, context.allocator); rerr == nil {
            defer delete(data)
            _lp := strings.split_lines(string(data), context.allocator)
            defer delete(_lp)
            for line in _lp {
                t := strings.trim_space(line)
                if t == "" {
                    continue
                }
                space := strings.index_byte(t, ' ')
                live := t
                if space > 0 {
                    live = t[:space]
                }
                os.remove(live)
                // Also remove .new if present.
                // tprintf temp; do NOT delete.
                new_path := fmt.tprintf("%s.new", live)
                os.remove(new_path)
            }
        }
    }
    // Delete the db dir entirely.
    os.remove_all(dir)
    return ""
}

// upgrade_package installs a new version alongside, flips symlinks on
// success, and prunes old versions (keeping one previous by default).
upgrade_package :: proc(m: ^manifest.Manifest, prefix: string, opts: ^Install_Opts, keep_previous: bool) -> string {
    name := m.pkg.name
    if !is_installed(opts.sysroot, name) {
        // Not installed; just install.
        return install_package(m, prefix, opts)
    }

    old_prefix := installed_prefix(opts.sysroot, name)
    defer delete(old_prefix)

    // Drop old symlinks first (they point at the old prefix).
    dir := installed_dir(opts.sysroot, name)
    defer delete(dir)
    sl_path, _ := filepath.join([]string{dir, "symlinks"})
    defer delete(sl_path)
    if sdata, serr := os.read_entire_file(sl_path, context.allocator); serr == nil {
        defer delete(sdata)
        _lsu := strings.split_lines(string(sdata), context.allocator)
        defer delete(_lsu)
        for line in _lsu {
            live := strings.trim_space(line)
            if live != "" {
                os.remove(live)
                registry_remove(opts.sysroot, live)
            }
        }
    }

    // Move the old db entry aside.
    backup_dir := fmt.aprintf("%s.upgrade-bak", dir)
    defer delete(backup_dir)
    if rerr := os.rename(dir, backup_dir); rerr != nil {
        return fmt.tprintf("upgrade: cannot backup db: %v", rerr)
    }

    err := install_package(m, prefix, opts)
    if err != "" {
        // Restore the backup.
        os.rename(backup_dir, dir)
        return err
    }

    // Success: handle old version.
    if keep_previous {
        prev_dir := fmt.aprintf("%s.previous", dir)
        defer delete(prev_dir)
        os.remove_all(prev_dir)
        os.rename(backup_dir, prev_dir)
    } else {
        if old_prefix != "" {
            os.remove_all(old_prefix)
        }
        os.remove_all(backup_dir)
    }
    return ""
}

// rollback_package repoints symlinks at the previous version.
rollback_package :: proc(sysroot, name: string, opts: ^Install_Opts) -> string {
    dir := installed_dir(sysroot, name)
    defer delete(dir)
    prev_dir := fmt.aprintf("%s.previous", dir)
    defer delete(prev_dir)
    if !os.exists(prev_dir) {
        return fmt.tprintf("rollback: no previous version for '%s'", name)
    }

    // Read the previous version.
    prev_version := db_read_version(prev_dir)
    defer delete(prev_version)
    if prev_version == "" {
        return "rollback: previous version unknown"
    }
    base := sysroot
    if base == "" {
        base = "/"
    }
    prev_prefix := fmt.aprintf("%s/usr/apps/%s/%s", strings.trim_suffix(base, "/"), name, prev_version)
    defer delete(prev_prefix)

    // Drop current symlinks.
    sl_path, _ := filepath.join([]string{dir, "symlinks"})
    defer delete(sl_path)
    if sdata, serr := os.read_entire_file(sl_path, context.allocator); serr == nil {
        defer delete(sdata)
        _ls := strings.split_lines(string(sdata), context.allocator)
        defer delete(_ls)
        for line in _ls {
            live := strings.trim_space(line)
            if live != "" {
                os.remove(live)
                registry_remove(sysroot, live)
            }
        }
    }

    // Recreate symlinks pointing at the previous prefix.
    // For each live path in the previous symlink list, the target is
    // prev_prefix + (live path with <sysroot>/usr/ stripped to /).
    prev_sl, _ := filepath.join([]string{prev_dir, "symlinks"})
    defer delete(prev_sl)
    if pdata, perr := os.read_entire_file(prev_sl, context.allocator); perr == nil {
        defer delete(pdata)
        _lps := strings.split_lines(string(pdata), context.allocator)
        defer delete(_lps)
        for line in _lps {
            live := strings.trim_space(line)
            if live == "" {
                continue
            }
            // live is like <sysroot>/usr/bin/foo; target is
            // <prev_prefix>/bin/foo.
            usr_prefix := fmt.aprintf("%s/usr/", strings.trim_suffix(base, "/"))
            defer delete(usr_prefix)
            rel: string
            if strings.has_prefix(live, usr_prefix) {
                rel = live[len(usr_prefix):]
            } else {
                continue
            }
            target, _ := filepath.join([]string{prev_prefix, rel})
            defer delete(target)
            parent := filepath.dir(live)
            if !os.exists(parent) {
                os.make_directory_all(parent)
            }
            os.symlink(target, live)
        }
    }

    // Swap db entries.
    tmp := fmt.aprintf("%s.tmp", dir)
    defer delete(tmp)
    os.rename(dir, tmp)
    os.rename(prev_dir, dir)
    os.rename(tmp, prev_dir)
    return ""
}

// db_read_version reads the version from a db dir's info file (owned).
db_read_version :: proc(dir: string) -> string {
    info_path, _ := filepath.join([]string{dir, "info"})
    defer delete(info_path)
    data, rerr := os.read_entire_file(info_path, context.allocator)
    if rerr != nil {
        return ""
    }
    defer delete(data)
    _lv := strings.split_lines(string(data), context.allocator)
    defer delete(_lv)
    for line in _lv {
        if strings.has_prefix(line, "version=") {
            return strings.clone(strings.trim_space(line[len("version="):]))
        }
    }
    return ""
}

// world_add records an explicit install.
world_add :: proc(sysroot, name: string) -> string {
    root := db_root(sysroot)
    defer delete(root)
    path, _ := filepath.join([]string{root, "world"})
    defer delete(path)
    // Append if not already present.
    if os.exists(path) {
        data, rerr := os.read_entire_file(path, context.allocator)
        if rerr == nil {
            defer delete(data)
            _l623 := strings.split_lines(string(data), context.allocator)
            defer delete(_l623)
            for line in _l623 {
                if strings.trim_space(line) == name {
                    return ""
                }
            }
        }
    }
    f, oerr := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other})
    if oerr != nil {
        return fmt.tprintf("db: cannot open world: %v", oerr)
    }
    defer os.close(f)
    if _, werr := os.write_string(f, fmt.tprintf("%s\n", name)); werr != nil {
        return fmt.tprintf("db: cannot write world: %v", werr)
    }
    return ""
}
