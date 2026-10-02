package main

import "core:fmt"
import "core:os"
import "core:strings"

import "norn:paths"

NORN_VERSION :: "0.1.0-alpha"

Config :: struct {
    sysroot:       string,
    create_pkgsrc: bool,
    paths:         paths.Context,
}

main :: proc() {
    cfg := Config{}
    rest := parse_global_flags(&cfg, os.args[1:])
    cfg.paths.sysroot = paths.normalize_sysroot(cfg.sysroot)

    if cfg.create_pkgsrc {
        cmd_create_pkgsrc(&cfg)
        return
    }

    if len(rest) == 0 {
        usage()
        os.exit(1)
    }
    cmd, cmd_args := rest[0], rest[1:]
    switch cmd {
    case "sync":
        cmd_sync(&cfg, cmd_args)
    case "install":
        cmd_install(&cfg, cmd_args)
    case "remove":
        cmd_remove(&cfg, cmd_args)
    case "purge":
        cmd_purge(&cfg, cmd_args)
    case "upgrade":
        cmd_upgrade(&cfg, cmd_args)
    case "rollback":
        cmd_rollback(&cfg, cmd_args)
    case "search":
        cmd_search(&cfg, cmd_args)
    case "info":
        cmd_info(&cfg, cmd_args)
    case "build":
        cmd_build(&cfg, cmd_args)
    case "clean":
        cmd_clean(&cfg, cmd_args)
    case "new":
        cmd_new(&cfg, cmd_args)
    case "version", "--version", "-V":
        fmt.println("norn", NORN_VERSION)
    case "help", "--help", "-h":
        usage()
    case:
        fmt.eprintf("norn: unknown command '%s'\n", cmd)
        usage()
        os.exit(1)
    }
}

// parse_global_flags consumes flags that precede the subcommand and
// returns the remaining arguments starting at the subcommand.
parse_global_flags :: proc(cfg: ^Config, args: []string) -> []string {
    i := 0
    for i < len(args) {
        a := args[i]
        if a == "--sysroot" {
            if i + 1 >= len(args) {
                fmt.eprintln("norn: --sysroot requires a directory")
                os.exit(1)
            }
            cfg.sysroot = args[i + 1]
            i += 2
        } else if a == "--create-pkgsrc" {
            cfg.create_pkgsrc = true
            i += 1
        } else if strings.has_prefix(a, "--sysroot=") {
            cfg.sysroot = a[len("--sysroot="):]
            i += 1
        } else {
            break
        }
    }
    return args[i:]
}
