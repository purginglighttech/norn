package main

import "core:fmt"
import "core:os"

import "norn:paths"

usage :: proc() {
    fmt.println("usage: norn [--sysroot DIR] <command> [args]")
    fmt.println()
    fmt.println("commands:")
    fmt.println("  sync                pull manifest tree HEAD (never touches installed packages)")
    fmt.println("  install <pkg>...    resolve, fetch, build, and install packages")
    fmt.println("  remove <pkg>...      uninstall, leaving copied configs and a tombstone")
    fmt.println("  purge <pkg>...       uninstall and delete configs and tombstone")
    fmt.println("  upgrade [pkg...]    upgrade packages (default: all)")
    fmt.println("  rollback <pkg>      revert a package to its previous version")
    fmt.println("  search <pattern>    search the manifest tree")
    fmt.println("  info <pkg>          show a package's manifest details")
    fmt.println("  build <pkg>         build a package without installing it")
    fmt.println("  clean               remove cached sources and build artifacts")
    fmt.println("  new <name>          scaffold a new <name>.pkgsrc manifest")
    fmt.println()
    fmt.println("global flags:")
    fmt.println("  --sysroot DIR       build/install into DIR instead of the live system")
    fmt.println("  --create-pkgsrc     interactively scaffold a <name>.pkgsrc manifest")
}

not_implemented :: proc(cmd: string) {
    fmt.eprintf("norn: '%s' is not yet implemented in this milestone\n", cmd)
    os.exit(1)
}

sync_usage :: proc() {
    fmt.println("usage: norn sync [--pin TAG | --unpin]")
    fmt.println()
    fmt.println("Pull the super-project, then sync each enabled subproject to")
    fmt.println("its recorded pin. Sync refreshes manifests only; installed")
    fmt.println("packages are never touched. The ports tree is host-side:")
    fmt.println("--sysroot does not apply.")
}

cmd_sync :: proc(_: ^Config, args: []string) {
    opts := Sync_Opts{
        ports_root  = paths.ports_root(),
        config_path = SYNC_CONFIG_PATH,
        pin_path    = SYNC_PIN_PATH,
        jj_bin      = "jj",
    }
    i := 0
    for i < len(args) {
        a := args[i]
        switch a {
        case "--pin":
            if i+1 >= len(args) {
                fmt.eprintln("norn sync: --pin requires a tag")
                os.exit(1)
            }
            opts.pin = args[i+1]
            i += 2
        case "--unpin":
            opts.unpin = true
            i += 1
        case "--help", "-h":
            sync_usage()
            return
        case:
            fmt.eprintf("norn sync: unknown flag '%s'\n", a)
            os.exit(1)
        }
    }
    if opts.pin != "" && opts.unpin {
        fmt.eprintln("norn sync: --pin and --unpin are mutually exclusive")
        os.exit(1)
    }
    if err := sync_tree(&opts); err != "" {
        fmt.eprintf("norn sync: %s\n", err)
        os.exit(1)
    }
}

cmd_install  :: proc(_: ^Config, _: []string) { not_implemented("install") }
cmd_remove   :: proc(_: ^Config, _: []string) { not_implemented("remove") }
cmd_purge    :: proc(_: ^Config, _: []string) { not_implemented("purge") }
cmd_upgrade  :: proc(_: ^Config, _: []string) { not_implemented("upgrade") }
cmd_rollback :: proc(_: ^Config, _: []string) { not_implemented("rollback") }
cmd_search   :: proc(_: ^Config, _: []string) { not_implemented("search") }
cmd_info     :: proc(_: ^Config, _: []string) { not_implemented("info") }
cmd_build    :: proc(_: ^Config, _: []string) { not_implemented("build") }
cmd_clean    :: proc(_: ^Config, _: []string) { not_implemented("clean") }
