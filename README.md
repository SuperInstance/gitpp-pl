# gitpp-pl

> A Perl 5 port of the git.pp fold. 6th fold port. Stdlib only (Digest::SHA + JSON::PP + Encode).

## What's in it

- `lib/Gitpp.pm` — the `Gitpp` Perl module with `record_leaf`, `closure_root`, `derive`, and `fold_with_closure` functions.
- `bin/gitpp-pl` — a CLI that reads a JSON record set from a file (or stdin), takes `--at <record>`, and prints the fold output as JSON.
- `t/leaf-encoding.t` — the byte-level regression suite: the four pinned cross-port leaves, the spec §2 canon bytes for all 32 C0 controls, and the placement rules for the string encoder. Core `Test::More` only.

## Tests

```bash
prove -Ilib t/          # 74 assertions, no network, no fixtures
```

The conformance CI (`.github/workflows/conformance.yml`) runs this first, then
the public corpus. `t/` is where the byte-level pins live; the corpus is where
the fold semantics live.
- `t/cycle-orphans.t` — the spec §5.5 orphan regression battery (13 discriminating cases + the §5.5 counterexample). Core Perl only (`Test::More`, `JSON::PP`).

## Build & run

```bash
# Run the CLI directly (Perl 5.10+ required; tested on 5.36)
perl bin/gitpp-pl records.json --at task-c

# Use it from another script
perl -Ilib -MGitpp -e '
  use JSON::PP;
  my $records = decode_json(`cat records.json`);
  my $d = Gitpp::fold_with_closure($records, "task-c");
  print "root: $d->{closureRoot}\n";
'
```

```bash
# Run the test suite (spec §5.5 orphan regression; no deps beyond core Perl)
prove -v t/cycle-orphans.t
```

Output is JSON:
```json
{
  "state": { "config.timeout": 45, "project": "poc-quilt-1", ... },
  "order": ["genesis", "task-a", "task-b", "override-1", ...],
  "conflicts": [
    { "key": "config.timeout", "winner": "override-1", "losers": ["task-a", "task-b", "task-d"] }
  ],
  "orphans": [],
  "closure": ["genesis", "override-1", "task-a", "task-b", "task-c"],
  "closureRoot": "60effe23970d8a5cc837636c44685502361288c1f00577e9addfa10cbd4fc91d"
}
```

## Pass criterion

**28 / 28** cases pass against the public conformance corpus (`SuperInstance/gitpp-conformance`), including:
- L1 (5): leaf construction — integer, signed-zero, float-scientific, parents-sorted, non-BMP ids.
- L2 (4): closure root — pinned, simple, incomplete, grown.
- F1 (8): fold resolution — class precedence, ancestry reduction, tie-breaks, conflict detection, orphan/cycle exclusion.
- F2 (4): topo order — Kahn, smallest-id-first, cycle/orphan exclusion.
- S1 (5): state assertions from the live `poc-quilt-1` set.
- V1 (4): three-way verdict — VERIFIED, STATE-ONLY, MISMATCH, missing-root.

Closure root at `poc-quilt-1@task-c` is `60effe23970d8a5cc837636c44685502361288c1f00577e9addfa10cbd4fc91d` — byte-for-byte match with the hub.

## Fixed in v0.1.10 — the other eighteen C0 controls

`_string()` escaped the seven C0 controls that have a two-character short form
(`\"` `\\` `\b` `\f` `\n` `\r` `\t`) and let the other eighteen through
**raw**. A record carrying U+0001 in a string value hashed a canon containing
the bare `0x01` byte — not legal JSON, and a byte no other port emits. Minimal
witness `{"id":"a","kind":"task","parents":[],"effects":{"c":"a\u0001b"},"reason":null}`:

| port | leaf |
|---|---|
| before | `2059a2b499ab997719e1e00f379f2fffe895c1ea7a865b22a8c80adb1a39191d` |
| reference (git.pp-doctor) | `f178bc60f931c55d98f085f5afc6a30fa0f86ef7e79545b535859b7201a43c19` |
| after | `f178bc60f931c55d98f085f5afc6a30fa0f86ef7e79545b535859b7201a43c19` |

The set of characters JSON requires escaped is defined by JSON, not by the
short forms Python's `json` module happens to prefer: `U+0000-U+0007`, `U+000B`
and `U+000E-U+001F` now emit `\u00xx` with **lowercase** hex, matching
`json.dumps`, `gitpp-c` and the other three ports. U+007F (DEL) is deliberately
left literal — RFC 8259 does not require it escaped and `json.dumps` emits it
raw, so escaping it would break agreement on any record containing one.

This is **not** a surrogate or non-ASCII defect. The pinned case-4 non-BMP id
(the rocket 🚀) was already correct and is unchanged: everything above U+007F
is still emitted literally, as spec §2 step 7 requires.

The new substitution runs **last** in `_string()`. It emits text that begins
with a literal backslash, so running it before `s/\\/\\\\/g` would feed
its own output back through the doubling and produce `\\u0001` — an escaped
backslash followed by the literal text `u0001`. Still a different leaf, but
silent. Running it last restores the invariant that no substitution ever
re-escapes text another substitution produced.

**Cross-port leaf verification (§3.5)**: all 4 pinned leaves in `git.pp-spec/cross-port-leafs.json` match byte-for-byte, including the non-BMP id case (the rocket emoji).

## Why a Perl port?

The 5 prior ports are TS (the hub), Python (the referee), Elixir (Beam), JS (4th), C# (5th). Perl is the canonical "pipes and regex" scripting language; it has the strongest Unicode support of any mainstream language (the `🚀` emoji is 4 bytes, not 2 surrogates). Useful for one-liners and legacy systems that already have Perl.

## Doc-only discipline (passed!)

This port was written from the `git.pp-spec` v0.3.0 spec alone, with zero reads of the other ports. The spec is now unambiguous about the byte-level leaf encoding (§2.5 worked example + §3.5 cross-port cases), so the doc-only discipline is enforceable.

The only place the spec wasn't enough was the JSON encoding — the spec says `, ` and `: ` as separators and "literal Unicode", but doesn't give the exact algorithm. So I wrote a custom JSON encoder (`canonical_json` in `lib/Gitpp.pm`) that produces the spec's exact format. It's ~30 lines of Perl and well-commented for future port authors.

## Perl-specific gotchas (for the next port author)

- JSON::PP returns booleans as `JSON::PP::Boolean` objects (blessed SCALARs), not `true`/`false` strings. The `EmitValue` function detects this with `ref($v) eq 'JSON::PP::Boolean'`.
- With the `utf8` pragma, Perl strings are stored as Unicode codepoints. The SHA function needs bytes, so `sha256_hex(Encode::encode_utf8($json))` is used.
- ARGV comes in as bytes by default. For non-ASCII record ids, the CLI decodes ARGV with `decode_utf8` before passing to the fold (else `exists $by_id{$at}` returns false for emoji ids).
- JSON::PP's `canonical(1)` does sort keys but uses compact JSON (no spaces). The spec requires `, ` and `: ` separators, so a custom encoder is needed.
- Perl's `\b` in regex is word-boundary, not backspace. Use `\x08` for backspace in the JSON string encoder.
- Perl strings are byte strings until something upgrades them, and a `\xNN` class in a substitution matches whichever kind it is handed. When pinning non-BMP behaviour, hash `Encode::encode_utf8($canon)` rather than `$canon`, or a regex like `/\xf0\xf9\x9a\x80/` silently tests the wrong thing — this suite shipped that bug for one commit.
- An **unpaired surrogate in the input document** is the one string case this port does not reject: `JSON::PP` decodes a lone `\uD800` to a Perl character of that code point, and `Encode::encode_utf8` then emits the WTF-8 bytes `ED A0 80` — not valid UTF-8, and a leaf no other port can reproduce. `gitpp-c` closed its side of this on `fix/escape-and-null-kind` by making an unpaired surrogate a hard parse error (exit non-zero). The same hard rejection is the right answer here; it is not implemented in this port yet.

## Why 6 ports?

Because fold ports are cheap to write once the spec is unambiguous, and each new port catches a different class of bug:
- The Python port caught the spec ambiguity in class precedence.
- The JS port caught the UTF-8-vs-`\uXXXX` divergence in the leaf encoding.
- The C# port caught the spec gap on Unicode escaping (now fixed in spec v0.3.0).
- The Perl port confirms the spec is now precise enough that a new port can be written from prose alone (doc-only discipline passed).

## License

Same as the rest of the quilt family: copyright SuperInstance, MIT.
