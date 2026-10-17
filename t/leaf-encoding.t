#!/usr/bin/env perl
# t/leaf-encoding.t -- the BYTE LEVEL of record_leaf (spec §2, §3.5).
#
# Every expectation in this file is a LITERAL: from SPEC.md §2 step 7, from
# git.pp-spec/cross-port-leafs.json, or from Python's json.dumps (the reference
# emitter). Nothing here is recomputed by the code under test.
#
# DEFECT, fixed in v0.1.10: _string() escaped the seven C0 controls that have a
# two-character short form and let the other eighteen through RAW. A record
# carrying U+0001 in a string value therefore hashed a canon containing the bare
# 0x01 byte -- not legal JSON, and a byte no other port emits. The four pinned
# cross-port leaves all passed anyway, because none of them contains a control
# character. Pin the case that DISTINGUISHES, not only the ones that agree.
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use Test::More;
use Gitpp;
use JSON::PP;
use Encode;

# ---------------------------------------------------------------- helpers

# The canon the spec hashes: the five fields, top-level keys sorted.
sub canon_of {
    my ($rec) = @_;
    return Gitpp::canonical_json({
        effects => $rec->{effects} // {},
        id      => $rec->{id},
        kind    => $rec->{kind},
        parents => [ sort @{$rec->{parents} // []} ],
        reason  => $rec->{reason},
    });
}

sub leaf_of_value {
    my ($s) = @_;                      # a string sitting in effects.c
    return Gitpp::record_leaf({
        id => "a", kind => "task", parents => [], effects => { c => $s }, reason => undef,
    });
}

# ------------------------------------------- DEFECT: C0 controls, all 32

# [ codepoint, the escape text json.dumps emits, which of the two sets ]
my @C0 = (
    [ 0x00, "\\u0000", q(no short form) ],
    [ 0x01, "\\u0001", q(no short form) ],
    [ 0x02, "\\u0002", q(no short form) ],
    [ 0x03, "\\u0003", q(no short form) ],
    [ 0x04, "\\u0004", q(no short form) ],
    [ 0x05, "\\u0005", q(no short form) ],
    [ 0x06, "\\u0006", q(no short form) ],
    [ 0x07, "\\u0007", q(no short form) ],
    [ 0x08, "\\b", q(short form) ],
    [ 0x09, "\\t", q(short form) ],
    [ 0x0a, "\\n", q(short form) ],
    [ 0x0b, "\\u000b", q(no short form) ],
    [ 0x0c, "\\f", q(short form) ],
    [ 0x0d, "\\r", q(short form) ],
    [ 0x0e, "\\u000e", q(no short form) ],
    [ 0x0f, "\\u000f", q(no short form) ],
    [ 0x10, "\\u0010", q(no short form) ],
    [ 0x11, "\\u0011", q(no short form) ],
    [ 0x12, "\\u0012", q(no short form) ],
    [ 0x13, "\\u0013", q(no short form) ],
    [ 0x14, "\\u0014", q(no short form) ],
    [ 0x15, "\\u0015", q(no short form) ],
    [ 0x16, "\\u0016", q(no short form) ],
    [ 0x17, "\\u0017", q(no short form) ],
    [ 0x18, "\\u0018", q(no short form) ],
    [ 0x19, "\\u0019", q(no short form) ],
    [ 0x1a, "\\u001a", q(no short form) ],
    [ 0x1b, "\\u001b", q(no short form) ],
    [ 0x1c, "\\u001c", q(no short form) ],
    [ 0x1d, "\\u001d", q(no short form) ],
    [ 0x1e, "\\u001e", q(no short form) ],
    [ 0x1f, "\\u001f", q(no short form) ],
);

my ($shorts, $missing) = (0, 0);
for my $row (@C0) {
    my ($cp, $esc, $kind) = @$row;
    my $want = qq({"effects": {"c": "$esc"}, "id": "a", "kind": "task", "parents": [], "reason": null});
    is(canon_of({ id => "a", kind => "task", parents => [], effects => { c => chr($cp) } }), $want,
       sprintf('U+%04X in a string value emits %s (%s)', $cp, $esc, $kind));
    $kind eq "short form" ? $shorts++ : $missing++;
}
diag("C0 sweep: $shorts short-form controls, $missing controls with no short form");

# The witness from the defect report.
is(leaf_of_value("a\x{1}b"), "f178bc60f931c55d98f085f5afc6a30fa0f86ef7e79545b535859b7201a43c19",
   "witness {effects:{c:\"a\\u0001b\"}} hashes to the reference leaf");

# The collision this bug would have allowed: two records that differ must not
# share a leaf.
isnt(leaf_of_value("ab"), leaf_of_value("a\x{1}b"),
     q{"ab" and "a\\u0001b" get DIFFERENT leaves});

# ------------------------------------------------ what must NOT be escaped

# U+007F (DEL) is not a C0 control: RFC 8259 does not require it escaped and
# json.dumps emits it literally. Escaping it here would put this port in
# disagreement with every other one on any record that contains one.
is(canon_of({ id => "a", kind => "task", parents => [], effects => { c => "\x{7f}" } }),
   qq({"effects": {"c": "\x{7f}"}, "id": "a", "kind": "task", "parents": [], "reason": null}),
   "U+007F (DEL) is emitted literally, like json.dumps");

# Non-BMP is a literal 4-byte sequence, never a \uXXXX pair (spec §2.5).
my $rocket = canon_of({ id => "\x{1f680}", kind => "task", parents => [], effects => {} });
unlike($rocket, qr/\\u[0-9a-f]{4}/, "non-BMP id emits no \\uXXXX escape");
like(Encode::encode_utf8($rocket), qr/\xf0\x9f\x9a\x80/,
     "non-BMP id emits the literal 4-byte UTF-8 sequence");

# ------------------------------- placement: the new sub must run LAST
#
# These pin the ordering itself. If the control sub ran before the backslash
# doubling, its own backslash would be doubled and the canon would read
# \\u0001 -- a different string, and a silent one.

is(canon_of({ id => "a", kind => "task", parents => [], effects => { c => "x\\\x{1}" } }),
   qq({"effects": {"c": "x\\\\\\u0001"}, "id": "a", "kind": "task", "parents": [], "reason": null}),
   "a control char after a literal backslash is NOT double-escaped");

is(canon_of({ id => "a", kind => "task", parents => [], effects => { c => "x\n\x{1b}" } }),
   qq({"effects": {"c": "x\\n\\u001b"}, "id": "a", "kind": "task", "parents": [], "reason": null}),
   "a control char after a short-form escape is NOT re-escaped");

is(canon_of({ id => "a", kind => "task", parents => [], effects => { c => "\"\x{1}\\\"" } }),
   qq({"effects": {"c": "\\"\\u0001\\\\\\""}, "id": "a", "kind": "task", "parents": [], "reason": null}),
   "quote + control + backslash + quote all escape independently");

# ------------------------------------------------ decode round trip (JSON::PP)
#
# gitpp-c shipped the mirror-image defect: its decoder DROPPED \uXXXX, so
# "a\u0001b" and "ab" produced the SAME leaf. Here the escape has to survive
# decoding and come back out as \u0001 in the canon.

my $from_escape = leaf_of_value("a\x{1}b");
my $recs = Gitpp::decode_records(
    q<[{"id":"a","kind":"task","parents":[],"effects":{"c":"a\u0001b"},"reason":null}]>);
is(Gitpp::record_leaf($recs->[0]), $from_escape,
   "a \u0001 in the INPUT json decodes to U+0001 and re-encodes to \u0001");

my $plain = Gitpp::decode_records(
    q<[{"id":"a","kind":"task","parents":[],"effects":{"c":"ab"},"reason":null}]>);
isnt(Gitpp::record_leaf($plain->[0]), $from_escape,
     q{the decoder does not DROP the \uXXXX escape ("ab" != "a\u0001b")});

# Every one of the 18 escapes the decoder must honour has to reach the encoder
# as a distinct character -- otherwise two different records share a leaf.
my %seen;
for my $cp (0x00 .. 0x07, 0x0b, 0x0e .. 0x1f) {
    my $r = Gitpp::decode_records(
        sprintf(q<[{"id":"a","kind":"task","parents":[],"effects":{"c":"\u%04x"},"reason":null}]>, $cp));
    my $leaf = Gitpp::record_leaf($r->[0]);
    ok(!$seen{$leaf}++, sprintf('decoded \u%04x has its own leaf', $cp));
}

# ------------------------------------- the four pinned cross-port leaves

# git.pp-spec/cross-port-leafs.json, verbatim. Case 4 is the non-BMP canary.
my @pinned = (
    [ 'case-1-minimal', { id => "a", kind => "task", parents => [], effects => {}, reason => undef },
      "229f56e059c1e8209d9e9c0a767ac70f02601f7abe53875069c7d55827533124" ],
    [ 'case-2-nested',
      { id => "b", kind => "task", parents => ["a"],
        effects => { x => { y => 1, z => [ 1, 2, 3 ] } }, reason => undef },
      "64a3cd29253cbeca672be7792c981ef3192bf23de2d6c0dee3708d611c496ad9" ],
    [ 'case-3-boolean-string',
      { id => "c", kind => "witness", parents => ["a"],
        effects => { ok => JSON::PP::true, msg => "ok" }, reason => "witnessed" },
      "97fd12eeb83d78a633613258d3357d84b6753861447a06525e4c54e18053f2f7" ],
    [ 'case-4-non-bmp-id',
      { id => "\x{1f680}", kind => "task", parents => ["c"], effects => { y => 1 }, reason => undef },
      "83d31b8135b406d8d518733c5f28f3218d1c50ff2a5da2aca6cf698e6905e597" ],
);
for my $p (@pinned) {
    my ($name, $rec, $want) = @$p;
    is(Gitpp::record_leaf($rec), $want, "pinned $name unchanged");
}

# ------------------------------------------------------ the CLI, end to end

# The same witness through bin/gitpp-pl: closure root at "a" is the SHA-256 of
# "a:<leaf>", so this covers the encoder through the process boundary.
my $cli = qx{$^X "$FindBin::RealBin/../bin/gitpp-pl" - --at a <<'JSON'
[{"id":"a","kind":"task","parents":[],"effects":{"c":"a\\u0001b"},"reason":null}]
JSON
};
like($cli, qr/6f907b0028707e8c24c20315f70cad90fdc1fc701cfdd3895a172e4365eb47d3/,
     "bin/gitpp-pl reaches the reference closure root on the witness");

done_testing();
