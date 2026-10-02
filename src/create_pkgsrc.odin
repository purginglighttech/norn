// norn --create-pkgsrc: interactive manifest wizard.
//
// Asks each question one at a time and scaffolds the <name>.pkgsrc file.
// Shares New_Opts and the renderer with the flag-driven `norn new`.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "norn:manifest"

cmd_create_pkgsrc :: proc(_: ^Config) {
    fmt.println("norn --create-pkgsrc")
    fmt.println("Answer each question; Enter accepts the [default]. Ctrl-D aborts.")
    fmt.println()

    o := New_Opts{
        out      = ".",
        version  = "0.1",
        release  = 1,
        priority = 0,
        vcs      = "jj",
    }

    name: string
    for {
        name = ask("package name")
        if valid_pkg_name(name) {
            break
        }
        fmt.println("  invalid name: no slashes, spaces, or bare '.'/'..'")
    }

    o.version     = ask("version", "0.1")
    o.release     = ask_int("release", 1)
    o.description = ask("one-line description")
    o.url         = ask("homepage URL")
    o.license     = ask("license (SPDX identifier)")
    o.priority    = ask_int("live-tree provider priority", 0)

    fmt.println()
    fmt.println("Source tier: norn tries repo first, then tarball, then binary.")
    ask_source_tier(&o)

    o.deps_build    = split_csv(ask("build dependencies (comma-separated)"))
    o.deps_run      = split_csv(ask("runtime dependencies (comma-separated)"))
    o.cflags_append = split_csv(ask("extra CFLAGS to append (comma-separated)"))

    o.out = ask("output directory", ".")

    path := pkgsrc_path(name, o.out)
    if os.exists(path) {
        fmt.printf("'%s' already exists.\n", path)
        if !ask_yes_no("overwrite it", false) {
            fmt.println("aborted.")
            os.exit(1)
        }
    }

    text := render_pkgsrc(name, &o)
    defer delete(text)
    if err := os.write_entire_file(path, transmute([]byte)text); err != nil {
        fmt.eprintf("norn: cannot write '%s': %v\n", path, err)
        os.exit(1)
    }
    fmt.printf("wrote %s\n", path)
    if o.tier == "" {
        fmt.println("no source tier selected: uncomment one tier before building.")
    }
}

// ask_source_tier walks the source-tier questions. Exactly one tier.
ask_source_tier :: proc(o: ^New_Opts) {
    choice := strings.to_lower(ask("source tier (repo/tarball/binary/skip)", "repo"))
    switch choice {
    case "repo":
        o.tier = "repo"
        for {
            o.vcs = ask("VCS", "jj")
            if manifest.is_known_vcs(o.vcs) {
                break
            }
            fmt.println("  unknown VCS")
        }
        for {
            o.repo_url = ask("repository URL")
            if o.repo_url != "" {
                break
            }
            fmt.println("  a repository URL is required")
        }
        o.branch = ask("branch (empty = upstream default)")
        o.tag = ask("last-known-good tag (empty = none)")
        if o.tag != "" {
            o.hash = ask("expected hash of that tag")
        }
    case "tarball":
        o.tier = "tarball"
        for {
            o.tarball_url = ask("tarball URL")
            if o.tarball_url != "" {
                break
            }
            fmt.println("  a URL is required")
        }
        for {
            o.sha256 = ask("sha256 of the tarball")
            if o.sha256 != "" {
                break
            }
            fmt.println("  a hash is required")
        }
    case "binary":
        o.tier = "binary"
        for {
            o.binary_url = ask("binary package URL")
            if o.binary_url != "" {
                break
            }
            fmt.println("  a URL is required")
        }
        for {
            o.sha256 = ask("sha256 of the package")
            if o.sha256 != "" {
                break
            }
            fmt.println("  a hash is required")
        }
    case "skip", "":
        o.tier = ""
    case:
        fmt.println("  unknown tier; leaving all tiers commented.")
        o.tier = ""
    }
}

// ask prints a prompt and reads one line. Empty input yields the default.
ask :: proc(prompt_text: string, default: string = "") -> string {
    if default != "" {
        fmt.printf("%s [%s]: ", prompt_text, default)
    } else {
        fmt.printf("%s: ", prompt_text)
    }
    line := strings.trim_space(read_line())
    if line == "" {
        return default
    }
    return line
}

// ask_int prompts until a valid integer (or the default) is given.
ask_int :: proc(prompt_text: string, default: i64) -> i64 {
    for {
        s := ask(prompt_text, fmt.tprintf("%d", default))
        n, ok := strconv.parse_i64(s)
        if ok {
            return n
        }
        fmt.println("  please enter an integer")
    }
}

// ask_yes_no prompts until a yes/no answer (or the default) is given.
ask_yes_no :: proc(prompt_text: string, default_yes: bool) -> bool {
    hint := "Y/n" if default_yes else "y/N"
    for {
        s := strings.to_lower(ask(fmt.tprintf("%s [%s]", prompt_text, hint)))
        switch s {
        case "":
            return default_yes
        case "y", "yes":
            return true
        case "n", "no":
            return false
        }
        fmt.println("  please answer y or n")
    }
}

// read_line reads one line from stdin, without the trailing newline.
// End of input aborts the wizard: it means the user bailed with Ctrl-D.
read_line :: proc() -> string {
    buf := make([dynamic]byte, 0, 64, context.allocator)
    one: [1]byte
    for {
        n, err := os.read(os.stdin, one[:])
        if n > 0 {
            if one[0] == '\n' {
                break
            }
            append(&buf, one[0])
        }
        if err != nil {
            if len(buf) == 0 {
                fmt.eprintln("\nnorn: end of input; aborting.")
                os.exit(1)
            }
            break
        }
    }
    if len(buf) > 0 && buf[len(buf)-1] == '\r' {
        pop(&buf)
    }
    // The buffer is intentionally never freed: answers alias it for the
    // rest of this short-lived run.
    return string(buf[:])
}
