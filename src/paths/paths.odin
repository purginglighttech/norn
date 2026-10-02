package paths

import "core:path/filepath"
import "core:strings"

// Context carries the sysroot that all target paths resolve under.
// A sysroot of "" means the live system.
Context :: struct {
    sysroot: string,
}

// normalize_sysroot cleans a raw --sysroot value once at startup.
// "" and "/" both mean the live system.
normalize_sysroot :: proc(sysroot: string) -> string {
    s := strings.trim_space(sysroot)
    if s == "" || s == "/" {
        return ""
    }
    for len(s) > 1 && s[len(s) - 1] == '/' {
        s = s[:len(s) - 1]
    }
    return s
}

// target resolves an absolute target path (e.g. "/usr/bin/ls") under the
// sysroot. Note the asymmetry, which is deliberate and load-bearing:
// symlink *targets* recorded by norn stay absolute ("/usr/apps/…") so they
// resolve correctly when the sysroot becomes the real root — only link
// *locations*, config copies, and database paths pass through here.
target :: proc(ctx: ^Context, abs_path: string) -> string {
    if ctx.sysroot == "" {
        return abs_path
    }
    joined, _ := filepath.join([]string{ctx.sysroot, abs_path}, context.allocator)
    return joined
}

// package_prefix returns the install PREFIX for a package in the target:
// <sysroot>/usr/apps/<name>/<version>
package_prefix :: proc(ctx: ^Context, name, version: string) -> string {
    prefix, _ := filepath.join([]string{"/usr/apps", name, version}, context.allocator)
    return target(ctx, prefix)
}

// db_root returns the local package database root in the target.
db_root :: proc(ctx: ^Context) -> string {
    return target(ctx, "/var/lib/norn")
}

// Host-side inputs are never redirected: the ports tree and the system
// build profile are read from the build host, not the sysroot.
ports_root :: proc() -> string {
    return "/usr/ports"
}

build_conf :: proc() -> string {
    return "/etc/norn/build.conf"
}
