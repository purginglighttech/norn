package manifest

import "core:testing"

@(test)
test_parse_subset :: proc(t: ^testing.T) {
    doc, err := parse_toml(
        "# a comment\n" +
        "[package]\n" +
        "name = \"sbase\" # trailing comment\n" +
        "version = \"0.1\"\n" +
        "release = 1\n" +
        "priority = 5\n" +
        "\n" +
        "[source.repo]\n" +
        "vcs = \"git\"\n" +
        "url = \"https://example.com/sbase\"\n" +
        "\n" +
        "[dependencies]\n" +
        "build = [\"bmake\", \"git\"]\n" +
        "run = []\n",
    )
    defer toml_doc_destroy(&doc)
    testing.expect(t, err.msg == "", "expected no parse error")

    v, ok := doc.values["package.name"].(string)
    testing.expect(t, ok && v == "sbase", "package.name")
    n, ok2 := doc.values["package.release"].(i64)
    testing.expect(t, ok2 && n == 1, "package.release")
    p, ok3 := doc.values["package.priority"].(i64)
    testing.expect(t, ok3 && p == 5, "package.priority")
    b, ok4 := doc.values["dependencies.build"].([]string)
    testing.expect(t, ok4 && len(b) == 2 && b[0] == "bmake" && b[1] == "git", "dependencies.build")
    e, ok5 := doc.values["dependencies.run"].([]string)
    testing.expect(t, ok5 && len(e) == 0, "dependencies.run empty")
}

@(test)
test_parse_errors :: proc(t: ^testing.T) {
    derr, err := parse_toml("[package]\nname = \"sbase\"\nname = \"dup\"\n")
    defer toml_doc_destroy(&derr)
    testing.expect(t, err.msg != "" && err.line == 3, "duplicate key is an error")

    derr2, err2 := parse_toml("[package]\nrelease = 1.5\n")
    defer toml_doc_destroy(&derr2)
    testing.expect(t, err2.msg != "", "floats are not in the subset")

    derr3, err3 := parse_toml("[package\nname = \"sbase\"\n")
    defer toml_doc_destroy(&derr3)
    testing.expect(t, err3.msg != "", "malformed table header is an error")
}

@(test)
test_manifest_bind :: proc(t: ^testing.T) {
    doc, err := parse_toml(
        "[package]\n" +
        "name = \"sbase\"\n" +
        "version = \"0.1\"\n" +
        "release = 1\n" +
        "[source.repo]\n" +
        "vcs = \"hg\"\n" +
        "url = \"https://example.com/sbase\"\n" +
        "[dependencies]\n" +
        "build = [\"hg\"]\n",
    )
    defer toml_doc_destroy(&doc)
    testing.expect(t, err.msg == "", "expected no parse error")

    m, merr := manifest_from_doc(&doc, "sbase.pkgsrc")
    testing.expect(t, merr.msg == "", "expected valid manifest")
    testing.expect(t, m.repo.present && m.repo.vcs == "hg", "repo tier with non-core vcs")
    testing.expect(t, len(m.deps.build) == 1 && m.deps.build[0] == "hg", "build dep carries the vcs client")
}

@(test)
test_manifest_rejects :: proc(t: ^testing.T) {
    // name does not match filename stem
    doc, _ := parse_toml("[package]\nname = \"other\"\nversion = \"0.1\"\nrelease = 1\n[source.repo]\nvcs = \"git\"\nurl = \"https://example.com/x\"\n")
    defer toml_doc_destroy(&doc)
    _, merr := manifest_from_doc(&doc, "sbase.pkgsrc")
    testing.expect(t, merr.msg != "", "name/filename mismatch is an error")

    // non-core vcs without a build dep
    doc2, _ := parse_toml("[package]\nname = \"sbase\"\nversion = \"0.1\"\nrelease = 1\n[source.repo]\nvcs = \"bzr\"\nurl = \"https://example.com/x\"\n")
    defer toml_doc_destroy(&doc2)
    _, merr2 := manifest_from_doc(&doc2, "sbase.pkgsrc")
    testing.expect(t, merr2.msg != "", "non-core vcs without build dep is an error")

    // no source tier at all
    doc3, _ := parse_toml("[package]\nname = \"sbase\"\nversion = \"0.1\"\nrelease = 1\n")
    defer toml_doc_destroy(&doc3)
    _, merr3 := manifest_from_doc(&doc3, "sbase.pkgsrc")
    testing.expect(t, merr3.msg != "", "missing source tier is an error")

    // unrecognized vcs
    doc4, _ := parse_toml("[package]\nname = \"sbase\"\nversion = \"0.1\"\nrelease = 1\n[source.repo]\nvcs = \"perforce\"\nurl = \"https://example.com/x\"\n")
    defer toml_doc_destroy(&doc4)
    _, merr4 := manifest_from_doc(&doc4, "sbase.pkgsrc")
    testing.expect(t, merr4.msg != "", "unrecognized vcs is an error")
}
