package main

import "core:strings"
import "core:testing"

import "norn:manifest"

// The generator's output must always satisfy the validator: render a
// manifest in-memory and run it through parse + schema binding.
@(test)
test_new_renders_valid_manifest :: proc(t: ^testing.T) {
    o := New_Opts{
        version  = "1.2",
        release  = 1,
        priority = 50,
        vcs      = "jj",
        tier     = "repo",
        repo_url = "https://example.com/sbase",
    }
    text := render_pkgsrc("sbase", &o)
    defer delete(text)

    doc, perr := manifest.parse_toml(text)
    defer manifest.toml_doc_destroy(&doc)
    testing.expectf(t, perr.msg == "", "generated manifest should parse, got: %s", perr.msg)
    if perr.msg != "" {
        return
    }
    m, merr := manifest.manifest_from_doc(&doc, "sbase.pkgsrc")
    testing.expectf(t, merr.msg == "", "generated manifest should validate, got: %s", merr.msg)
    testing.expect_value(t, m.pkg.name, "sbase")
    testing.expect_value(t, m.pkg.version, "1.2")
    testing.expect_value(t, m.repo.present, true)
    testing.expect_value(t, m.repo.vcs, "jj")
    testing.expect_value(t, m.repo.url, "https://example.com/sbase")
}

// A non-core VCS must land in dependencies.build automatically.
@(test)
test_new_noncore_vcs_gets_build_dep :: proc(t: ^testing.T) {
    o := New_Opts{
        vcs      = "hg",
        tier     = "repo",
        repo_url = "https://example.com/legacy",
    }
    text := render_pkgsrc("legacy", &o)
    defer delete(text)

    testing.expect(t, strings.contains(text, "build = [\"hg\"]"), "hg should be auto-declared in dependencies.build")

    doc, perr := manifest.parse_toml(text)
    defer manifest.toml_doc_destroy(&doc)
    testing.expect(t, perr.msg == "", "generated manifest should parse")
    _, merr := manifest.manifest_from_doc(&doc, "legacy.pkgsrc")
    testing.expectf(t, merr.msg == "", "non-core VCS with build dep should validate, got: %s", merr.msg)
}

// With no tier flags the file is a commented template: it parses, but
// validation must reject it until a tier is uncommented.
@(test)
test_new_no_tier_is_template_only :: proc(t: ^testing.T) {
    o := New_Opts{}
    text := render_pkgsrc("skeleton", &o)
    defer delete(text)

    doc, perr := manifest.parse_toml(text)
    defer manifest.toml_doc_destroy(&doc)
    testing.expect(t, perr.msg == "", "template should parse")
    _, merr := manifest.manifest_from_doc(&doc, "skeleton.pkgsrc")
    testing.expect(t, merr.msg != "", "template without a tier must fail validation")
}

@(test)
test_new_toml_escape :: proc(t: ^testing.T) {
    e := toml_escape("say \"hi\" \\ bye")
    defer delete(e)
    // toml_escape returns the fully quoted string.
    testing.expect_value(t, e, "\"say \\\"hi\\\" \\\\ bye\"")
}

@(test)
test_new_valid_pkg_name :: proc(t: ^testing.T) {
    testing.expect(t, valid_pkg_name("sbase"))
    testing.expect(t, valid_pkg_name("xorg-server"))
    testing.expect(t, !valid_pkg_name(""))
    testing.expect(t, !valid_pkg_name("."))
    testing.expect(t, !valid_pkg_name("../evil"))
    testing.expect(t, !valid_pkg_name("has space"))
}
