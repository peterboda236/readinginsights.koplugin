#!/usr/bin/env python3
"""Reading Insights - translation consistency check (run before a release).

Compares the msgids of every locale/*.po with the strings the Lua code
actually asks for, and reports:

  MISSING   used in code (_("..."), N_("a", "b", n))
            but absent from that .po
  EMPTY     msgid whose msgstr is really empty after joining the
            continuation lines (so multi-line entries are NOT flagged)
  UNUSED    in the .po, but the string appears nowhere in the Lua code
            (not even as a plain literal, which covers table-driven keys
            like month / weekday names that are passed to _(var)) -
            probably a dead key
  ONLY-IN   msgids present in some .po files but not in others

Usage:  python3 tools/check_po.py [--strict] [--lang hu]
Exit code 1 with --strict when any MISSING / EMPTY entry exists.
Run from anywhere; paths are resolved relative to this file.
"""
import re, sys, glob, os, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Keys that are deliberately translated in some languages only: the code falls
# back to the English pattern / default when a .po has no entry for them, so
# their absence is not an error. (Do not report them as MISSING.)
OPTIONAL_KEYS = {
    "%1 \u2013 %2 %3",        # heatmap range label; en pattern is the fallback
    "%1 %2 \u2013 %3 %4",
    "range months lowercase",  # opt-in switch in lib/locale.lua ("yes" in hu.po)
}

ESC = {"n": "\n", "t": "\t", '"': '"', "'": "'", "\\": "\\", "r": "\r"}

def unescape(s):
    return re.sub(r'\\(.)', lambda m: ESC.get(m.group(1), "\\" + m.group(1)), s)

# ---------- Lua side ----------
def lua_unescape(body):
    """Decode a Lua short-string body (\\n, \\xHH, \\ddd, \\u{...}, \\z ...)."""
    out, i = bytearray(), 0
    simple = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b",
              "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}
    while i < len(body):
        c = body[i]
        if c != "\\":
            out += c.encode("utf-8"); i += 1; continue
        i += 1
        c = body[i] if i < len(body) else ""
        if c in simple:
            out += simple[c].encode(); i += 1
        elif c == "x":
            out.append(int(body[i + 1:i + 3], 16)); i += 3
        elif c.isdigit():
            j = i
            while j < len(body) and j < i + 3 and body[j].isdigit():
                j += 1
            out.append(int(body[i:j]) & 255); i = j
        elif c == "u":
            j = body.index("}", i)
            out += chr(int(body[i + 2:j], 16)).encode("utf-8"); i = j + 1
        elif c == "z":
            i += 1
            while i < len(body) and body[i].isspace():
                i += 1
        else:
            out += ("\\" + c).encode(); i += 1
    return out.decode("utf-8", "replace")

def tokenize(src):
    """Yield (kind, value, line): kind is 'str', 'name' or 'op'. Comments are skipped."""
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1
        elif c.isspace():
            i += 1
        elif src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i)
                j = n if j < 0 else j + len(close)
                line += src.count("\n", i, j); i = j
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            body = src[i + 1:j]
            yield "str", lua_unescape(body), line
            line += body.count("\n"); i = j + 1
        elif c == "[" and re.match(r"\[=*\[", src[i:]):
            lvl = re.match(r"\[(=*)\[", src[i:]).group(1)
            close = "]" + lvl + "]"
            j = src.find(close, i)
            j = n if j < 0 else j
            body = src[i + len(lvl) + 2:j]
            yield "str", body, line
            line += body.count("\n"); i = j + len(close)
        elif c.isalpha() or c == "_":
            m = re.match(r"[A-Za-z_]\w*", src[i:])
            yield "name", m.group(0), line; i += m.end()
        elif src.startswith("..", i):
            yield "op", "..", line; i += 2
        else:
            yield "op", c, line; i += 1

def read_strings(toks, k):
    """toks[k] is a string; follow `.. "more"` chains. Returns (value, next_index)."""
    val = toks[k][1]; k += 1
    while k + 1 < len(toks) and toks[k][:2] == ("op", "..") and toks[k + 1][0] == "str":
        val += toks[k + 1][1]; k += 2
    return val, k

def collect_code():
    keys = collections.defaultdict(set)   # key -> {file:line}
    literals = set()
    for f in glob.glob(os.path.join(ROOT, "**", "*.lua"), recursive=True):
        rel = os.path.relpath(f, ROOT)
        toks = list(tokenize(open(f, encoding="utf-8").read()))
        for t in toks:
            if t[0] == "str":
                literals.add(t[1])
        for k, t in enumerate(toks):
            if t[0] != "name" or t[1] not in ("_", "N_"):
                continue
            if k and toks[k - 1][:2] in (("op", "."), ("op", ":")):
                continue                      # a method / field, not the gettext function
            if k + 2 >= len(toks) or toks[k + 1][:2] != ("op", "(") or toks[k + 2][0] != "str":
                continue                      # _(variable): covered by the literal scan
            val, nxt = read_strings(toks, k + 2)
            keys[val].add(f"{rel}:{t[2]}")
            if t[1] == "N_" and toks[nxt][:2] == ("op", ",") and toks[nxt + 1][0] == "str":
                val2, _ = read_strings(toks, nxt + 1)
                keys[val2].add(f"{rel}:{t[2]}")
    return keys, literals

# ---------- .po side ----------
def parse_po(path):
    entries, cur, field = {}, {"msgid": None, "msgstr": None}, None
    def flush():
        if cur["msgid"] is not None and cur["msgstr"] is not None:
            entries[cur["msgid"]] = cur["msgstr"]
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if line.startswith("#") or not line:
            if not line:
                flush(); cur["msgid"] = cur["msgstr"] = None; field = None
            continue
        m = re.match(r'^(msgid|msgstr)\s+"(.*)"$', line)
        if m:
            if m.group(1) == "msgid":
                flush(); cur["msgid"] = cur["msgstr"] = None
            field = m.group(1)
            cur[field] = unescape(m.group(2))
            continue
        m = re.match(r'^"(.*)"$', line)
        if m and field:
            cur[field] = (cur[field] or "") + unescape(m.group(1))
    flush()
    entries.pop("", None)           # the header
    return entries

def main():
    strict = "--strict" in sys.argv
    only = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else None
    code, literals = collect_code()
    pos = {os.path.basename(p)[:-3]: parse_po(p)
           for p in sorted(glob.glob(os.path.join(ROOT, "locale", "*.po")))}
    bad = 0
    print(f"{len(code)} distinct keys in code, {len(pos)} .po files: {', '.join(pos)}\n")
    union = set().union(*[set(p) for p in pos.values()])
    for lang, entries in pos.items():
        if only and lang != only:
            continue
        missing = sorted(k for k in code if k not in entries and k not in OPTIONAL_KEYS)
        empty = sorted(k for k, v in entries.items() if v.strip() == "")
        unused = sorted(k for k in entries if k not in code and k not in literals)
        absent = sorted(k for k in union if k not in entries and k not in OPTIONAL_KEYS)
        print(f"=== {lang}: {len(entries)} msgids")
        for title, items, where in (("MISSING", missing, True), ("EMPTY", empty, False),
                                    ("UNUSED", unused, False), ("ONLY-IN-OTHERS", absent, False)):
            if not items:
                continue
            print(f"  {title} ({len(items)}):")
            for k in items:
                loc = f"   <- {sorted(code[k])[0]}" if where and k in code else ""
                print(f"    {k!r}{loc}")
        if missing or empty:
            bad += 1
        print()
    if strict and bad:
        sys.exit(1)

if __name__ == "__main__":
    main()
