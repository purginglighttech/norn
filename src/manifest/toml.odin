package manifest

import "core:strconv"
import "core:strings"

// Restricted TOML subset used by norn for manifests and configuration:
// tables and sub-tables, strings, integers, booleans, arrays of strings.
// Anything else is a parse error carrying a 1-based line number.

Toml_Value :: union {
    string,
    i64,
    bool,
    []string,
}

Toml_Doc :: struct {
    values: map[string]Toml_Value,
}

Parse_Error :: struct {
    line: int,    // 1-based; 0 means no error
    msg:  string, // empty means no error
}

// parse_toml parses the restricted TOML subset into a flat map of
// dotted keys ("source.repo.vcs") to values.
//
// Ownership: the returned document owns every key and every value —
// keys are always freshly allocated, even without a table prefix
// (otherwise they would alias the input). Release the document with
// toml_doc_destroy, including when err.msg != "": a failed parse may
// leave it partially populated. Anything borrowed from the document
// (e.g. by manifest_from_doc) is valid only until it is destroyed.
parse_toml :: proc(src: string) -> (doc: Toml_Doc, err: Parse_Error) {
    doc.values = make(map[string]Toml_Value)
    lines := strings.split_lines(src)
    defer delete(lines)
    prefix := ""
    line_no := 0
    for line in lines {
        line_no += 1
        t := strings.trim_space(line)
        if len(t) == 0 || t[0] == '#' {
            continue
        }
        if t[0] == '[' {
            if len(t) < 3 || t[len(t) - 1] != ']' {
                err = Parse_Error{line_no, "malformed table header"}
                return
            }
            name := strings.trim_space(t[1:len(t) - 1])
            if !valid_dotted_key(name) {
                err = Parse_Error{line_no, "invalid table name"}
                return
            }
            prefix = name
            continue
        }
        eq := strings.index_byte(t, '=')
        if eq < 0 {
            err = Parse_Error{line_no, "expected 'key = value'"}
            return
        }
        key := strings.trim_space(t[:eq])
        if !valid_key(key) {
            err = Parse_Error{line_no, "invalid key"}
            return
        }
        raw := strip_comment(strings.trim_space(t[eq + 1:]))
        val, ok := parse_value(raw)
        if !ok {
            err = Parse_Error{line_no, "invalid value"}
            return
        }
        full: string
        if len(prefix) > 0 {
            full = join_key(prefix, key)
        } else {
            // Clone: without a prefix the key would otherwise alias the
            // input, and the document must own all of its keys.
            full = strings.clone(key)
        }
        if full in doc.values {
            delete(full)
            toml_value_destroy(val)
            err = Parse_Error{line_no, "duplicate key"}
            return
        }
        doc.values[full] = val
    }
    return doc, Parse_Error{}
}

// join_key builds "prefix.key" as a freshly allocated string.
join_key :: proc(prefix, key: string) -> string {
    buf := make([]u8, len(prefix) + 1 + len(key), context.allocator)
    copy(buf, prefix)
    buf[len(prefix)] = '.'
    copy(buf[len(prefix) + 1:], key)
    return string(buf)
}

parse_value :: proc(raw: string) -> (Toml_Value, bool) {
    raw := strings.trim_space(raw)
    if len(raw) == 0 {
        return nil, false
    }
    c := raw[0]
    if c == '"' {
        s, ok := parse_basic_string(raw)
        if !ok {
            return nil, false
        }
        return s, true
    }
    if c == '[' {
        return parse_string_array(raw)
    }
    if raw == "true" {
        return true, true
    }
    if raw == "false" {
        return false, true
    }
    if c == '-' || c == '+' || (c >= '0' && c <= '9') {
        n, ok := strconv.parse_i64(raw)
        if !ok {
            return nil, false
        }
        return n, true
    }
    return nil, false
}

// parse_basic_string parses a double-quoted string; raw must start with
// the opening quote and end with the closing quote (comments are stripped
// before this runs). Supports \" \\ \n \t escapes.
parse_basic_string :: proc(raw: string) -> (string, bool) {
    if len(raw) < 2 || raw[0] != '"' {
        return "", false
    }
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    i := 1
    for i < len(raw) {
        c := raw[i]
        if c == '\\' {
            if i + 1 >= len(raw) {
                return "", false
            }
            switch raw[i + 1] {
            case '"':
                strings.write_byte(&sb, '"')
            case '\\':
                strings.write_byte(&sb, '\\')
            case 'n':
                strings.write_byte(&sb, '\n')
            case 't':
                strings.write_byte(&sb, '\t')
            case:
                return "", false
            }
            i += 2
            continue
        }
        if c == '"' {
            if i != len(raw) - 1 {
                return "", false
            }
            // to_string aliases the builder buffer, so clone before
            // the deferred destroy runs.
            return strings.clone(strings.to_string(sb)), true
        }
        strings.write_byte(&sb, c)
        i += 1
    }
    return "", false
}

// parse_string_array parses ["a", "b"] — strings only, per the subset.
parse_string_array :: proc(raw: string) -> (Toml_Value, bool) {
    if len(raw) < 2 || raw[0] != '[' || raw[len(raw) - 1] != ']' {
        return nil, false
    }
    inner := strings.trim_space(raw[1:len(raw) - 1])
    if len(inner) == 0 {
        return []string{}, true
    }
    out := make([dynamic]string, 0, 4, context.allocator)
    parts := split_top_level(inner)
    defer delete(parts)
    for part in parts {
        s, ok := parse_basic_string(strings.trim_space(part))
        if !ok {
            for e in out {
                delete(e)
            }
            delete(out)
            return nil, false
        }
        append(&out, s)
    }
    return out[:], true
}

// split_top_level splits on commas that are not inside strings.
split_top_level :: proc(s: string) -> []string {
    parts := make([dynamic]string, 0, 4, context.allocator)
    start := 0
    in_str := false
    i := 0
    for i < len(s) {
        c := s[i]
        if in_str {
            if c == '\\' {
                i += 2
                continue
            }
            if c == '"' {
                in_str = false
            }
        } else {
            if c == '"' {
                in_str = true
            } else if c == ',' {
                append(&parts, s[start:i])
                start = i + 1
            }
        }
        i += 1
    }
    append(&parts, s[start:])
    return parts[:]
}

// strip_comment removes a trailing # comment, ignoring # inside strings.
strip_comment :: proc(s: string) -> string {
    in_str := false
    i := 0
    for i < len(s) {
        c := s[i]
        if in_str {
            if c == '\\' {
                i += 2
                continue
            }
            if c == '"' {
                in_str = false
            }
        } else {
            if c == '"' {
                in_str = true
            } else if c == '#' {
                return strings.trim_space(s[:i])
            }
        }
        i += 1
    }
    return s
}

valid_key :: proc(s: string) -> bool {
    if len(s) == 0 {
        return false
    }
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
        if !ok {
            return false
        }
    }
    return true
}

valid_dotted_key :: proc(s: string) -> bool {
    if len(s) == 0 {
        return false
    }
    parts := strings.split(s, ".")
    defer delete(parts)
    for part in parts {
        if !valid_key(part) {
            return false
        }
    }
    return true
}

// toml_value_destroy frees the heap memory owned by a parsed value:
// strings, and string arrays (each element plus the backing array).
// Integers and booleans own nothing.
toml_value_destroy :: proc(v: Toml_Value) {
    switch s in v {
    case string:
        delete(s)
    case []string:
        for e in s {
            delete(e)
        }
        delete(s)
    case i64:
    case bool:
    }
}

// toml_doc_destroy frees every allocation owned by a parsed document:
// all keys, all values, and the map itself. Call it for every document
// returned by parse_toml, including on parse errors — a failed parse
// may leave the document partially populated.
toml_doc_destroy :: proc(doc: ^Toml_Doc) {
    for k, v in doc.values {
        delete(k)
        toml_value_destroy(v)
    }
    delete(doc.values)
}
