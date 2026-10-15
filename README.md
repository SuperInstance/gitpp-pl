# gitpp-pl

> A Perl 5 port of the git.pp fold. 6th fold port. Stdlib only (Digest::SHA + JSON::PP + Encode).

## What's in it

- `lib/Gitpp.pm` — the `Gitpp` Perl module with `record_leaf`, `closure_root`, `derive`, and `fold_with_closure` functions.
- `bin/gitpp-pl` — a CLI that reads a JSON record set from a file (or stdin), takes `--at <record>`, and prints the fold output as JSON.

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

## Why 6 ports?

Because fold ports are cheap to write once the spec is unambiguous, and each new port catches a different class of bug:
- The Python port caught the spec ambiguity in class precedence.
- The JS port caught the UTF-8-vs-`\uXXXX` divergence in the leaf encoding.
- The C# port caught the spec gap on Unicode escaping (now fixed in spec v0.3.0).
- The Perl port confirms the spec is now precise enough that a new port can be written from prose alone (doc-only discipline passed).

## License

Same as the rest of the quilt family: copyright SuperInstance, MIT.
