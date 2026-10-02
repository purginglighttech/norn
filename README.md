# norn

Source-first package manager for the permissive Linux distro. Alpha draft;
working name. Written in Odin, MIT licensed.

Living specification: `../your_files/norn-spec/norn-spec.md` — the code
follows it; the spec is the authority when they disagree.

## Layout

```
src/
  main.odin        CLI entry, global flags (--sysroot), subcommand dispatch
  commands.odin    subcommand implementations (stubs until their milestone)
  new.odin         `norn new`: scaffold a <name>.pkgsrc manifest from flags
  create_pkgsrc.odin  `norn --create-pkgsrc`: interactive manifest wizard
  sync.odin        `norn sync`: super-project/subproject tree sync via jj
  fetch.odin       source fetching: VCS / tarball / binary tiers + sha256
  deps.odin        dependency resolution: topo order, cycles, core containment
  paths/           sysroot-aware target path resolution
  manifest/        restricted-TOML parser + .pkgsrc schema validation
```

## Build

Requires the Odin compiler (https://odin-lang.org).

```sh
./build.sh         # produces ./norn
./build.sh test    # runs the manifest and main package tests
```

## Milestones

- **M1** (done): manifest parsing + validation, CLI skeleton, sysroot paths,
  `norn new` / `norn --create-pkgsrc` manifest scaffolding (implemented, tested)
- **M2** (done): repo management — `norn sync` via jj, `/usr/ports/<repo>/` layout,
  super-project pins (`--pin`/`--unpin`), pin recorded at `/etc/norn/ports.pin`
  (implemented, tested)
- **M3** (done): fetch tiers — VCS (jj/fossil; branch/HEAD, fallback to
  last-known-good tag+hash) → tarball → binary, sha256-verified; `fetch_mode`
  from `/etc/norn/config.toml` (implemented, tested)
- **M4** (done): dependency resolution — topological order, cycles are hard
  errors naming the loop, core-containment check (implemented, tested)
- **M5**: build pipeline — `/etc/norn/build.conf`, `$PREFIX`, fakeroot shim hook
- **M6**: install/remove/purge/upgrade/rollback, priority registry, config-file
  lifecycle, local database under `/var/lib/norn`
- **M7**: `.pkgsrc` manifests for every alpha core package
- **M8**: bootstrap — host Odin builds norn; `norn --sysroot` builds the alpha;
  the alpha boots

## Notes

- norn itself is pure Odin with no dependencies beyond the Odin core library.
- `--sysroot DIR` redirects all *target* paths; the ports tree and
  `build.conf` are always read from the build host.
- The build machine needs the Odin toolchain; there is deliberately no
  configure step.
