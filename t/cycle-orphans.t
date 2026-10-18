#!/usr/bin/perl
# t/cycle-orphans.t -- spec §5.5 orphan regression.
#
# The 13 cases below are the discriminating set from SuperInstance/gitpp-reading-room
# (readers/py/cyclefix.py, CASES). No single natural rule passes all of them:
#
#   rule A  "any parent missing from the record set"  correct on cycle members,
#                                                       WRONG on cycle descendants
#   rule B  "anything Kahn never emitted"               correct on cycle descendants,
#                                                       WRONG on missing-parent descendants
#   rule U3 three clauses                               correct on both
#
# The three load-bearing ones:
#
#   "desc of missing"    orphans must be ["orph"] ONLY. The kid's parent EXISTS
#                       (orphaned, not absent), so the kid is orderable and is
#                       NOT an orphan. Rule B regresses this.
#   "desc of 2-cycle"   orphans must be ["ca","cb","down"]. Rule A misses "down",
#                       whose parent exists but can never be topologically ordered.
#   "missing AND cycle" orphans must be ["ca","cb","m"]. Rule A returns ["m"],
#                       rule B returns ["ca","cb"]. Neither single rule passes.
#
# Records go in as JSON and are decoded with Gitpp::decode_records, the same
# entry point the CLI uses, so this exercises the real input path.
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use Test::More;
use Gitpp;

my @CASES = (
    {
        name    => 'clean chain',
        records => '[{"id":"a","kind":"task","parents":[],"effects":{},"reason":null},{"id":"b","kind":"task","parents":["a"],"effects":{"x":1},"reason":null}]',
        orphans => [  ],
        state   => { 'x' => 1 },
    },
    {
        name    => 'missing parent',
        records => '[{"id":"a","kind":"task","parents":["ghost"],"effects":{"x":1},"reason":null}]',
        orphans => [ 'a' ],
        state   => {},
    },
    {
        name    => 'desc of missing',
        records => '[{"id":"orph","kind":"task","parents":["ghost"],"effects":{"x":1},"reason":null},{"id":"kid","kind":"task","parents":["orph"],"effects":{"y":2},"reason":null}]',
        orphans => [ 'orph' ],
        state   => { 'y' => 2 },
    },
    {
        name    => '2-cycle',
        records => '[{"id":"ca","kind":"task","parents":["cb"],"effects":{},"reason":null},{"id":"cb","kind":"task","parents":["ca"],"effects":{},"reason":null}]',
        orphans => [ 'ca', 'cb' ],
        state   => {},
    },
    {
        name    => 'desc of 2-cycle',
        records => '[{"id":"ca","kind":"task","parents":["cb"],"effects":{},"reason":null},{"id":"cb","kind":"task","parents":["ca"],"effects":{},"reason":null},{"id":"down","kind":"task","parents":["cb"],"effects":{"y":3},"reason":null}]',
        orphans => [ 'ca', 'cb', 'down' ],
        state   => {},
    },
    {
        name    => 'desc^2 of 2-cycle',
        records => '[{"id":"ca","kind":"task","parents":["cb"],"effects":{},"reason":null},{"id":"cb","kind":"task","parents":["ca"],"effects":{},"reason":null},{"id":"d1","kind":"task","parents":["cb"],"effects":{},"reason":null},{"id":"d2","kind":"task","parents":["d1"],"effects":{"y":4},"reason":null}]',
        orphans => [ 'ca', 'cb', 'd1', 'd2' ],
        state   => {},
    },
    {
        name    => 'cycle + root',
        records => '[{"id":"ca","kind":"task","parents":["cb"],"effects":{},"reason":null},{"id":"cb","kind":"task","parents":["ca"],"effects":{},"reason":null},{"id":"ok","kind":"task","parents":[],"effects":{"z":5},"reason":null}]',
        orphans => [ 'ca', 'cb' ],
        state   => { 'z' => 5 },
    },
    {
        name    => 'two cycles',
        records => '[{"id":"a","kind":"task","parents":["b"],"effects":{},"reason":null},{"id":"b","kind":"task","parents":["a"],"effects":{},"reason":null},{"id":"c","kind":"task","parents":["d"],"effects":{},"reason":null},{"id":"d","kind":"task","parents":["c"],"effects":{},"reason":null}]',
        orphans => [ 'a', 'b', 'c', 'd' ],
        state   => {},
    },
    {
        name    => 'self-loop',
        records => '[{"id":"a","kind":"task","parents":["a"],"effects":{"x":6},"reason":null}]',
        orphans => [ 'a' ],
        state   => {},
    },
    {
        name    => 'desc of self-loop',
        records => '[{"id":"a","kind":"task","parents":["a"],"effects":{},"reason":null},{"id":"k","kind":"task","parents":["a"],"effects":{"y":7},"reason":null}]',
        orphans => [ 'a', 'k' ],
        state   => {},
    },
    {
        name    => 'diamond',
        records => '[{"id":"r","kind":"task","parents":[],"effects":{},"reason":null},{"id":"l","kind":"task","parents":["r"],"effects":{},"reason":null},{"id":"m","kind":"task","parents":["r"],"effects":{},"reason":null},{"id":"j","kind":"task","parents":["l","m"],"effects":{"x":8},"reason":null}]',
        orphans => [  ],
        state   => { 'x' => 8 },
    },
    {
        name    => 'cycle + branch',
        records => '[{"id":"a","kind":"task","parents":["b"],"effects":{},"reason":null},{"id":"b","kind":"task","parents":["a"],"effects":{},"reason":null},{"id":"t","kind":"task","parents":["r"],"effects":{},"reason":null},{"id":"r","kind":"task","parents":["t"],"effects":{},"reason":null},{"id":"leaf","kind":"task","parents":["r"],"effects":{"x":9},"reason":null}]',
        orphans => [ 'a', 'b', 'leaf', 'r', 't' ],
        state   => {},
    },
    {
        name    => 'missing AND cycle',
        records => '[{"id":"ca","kind":"task","parents":["cb"],"effects":{},"reason":null},{"id":"cb","kind":"task","parents":["ca"],"effects":{},"reason":null},{"id":"m","kind":"task","parents":["ghost"],"effects":{"q":1},"reason":null},{"id":"mk","kind":"task","parents":["m"],"effects":{"w":2},"reason":null}]',
        orphans => [ 'ca', 'cb', 'm' ],
        state   => { 'w' => 2 },
    },
);

for my $c (@CASES) {
    my $records = Gitpp::decode_records($c->{records});
    my $d = Gitpp::derive($records);
    is_deeply($d->{orphans}, $c->{orphans}, "orphans: $c->{name}");
    is_deeply($d->{state}, $c->{state}, "state: $c->{name}");
}

# The counterexample from the spec §5.5 discussion, spelled out on its own so
# the regression is readable without the table above.
{
    my $records = Gitpp::decode_records(
        '[{"id":"ca","kind":"task","parents":["cb"],"effects":{"x":"cycle-a"}},'
      . '{"id":"cb","kind":"task","parents":["ca"],"effects":{"x":"cycle-b"}},'
      . '{"id":"down","kind":"task","parents":["cb"],"effects":{"y":"downstream"}},'
      . '{"id":"ok","kind":"task","parents":[],"effects":{"z":"fine"}}]'
    );
    my $d = Gitpp::derive($records);
    is_deeply($d->{orphans}, [ 'ca', 'cb', 'down' ],
              'orphans: counterexample (cycle descendant)');
    is_deeply($d->{state}, { 'z' => 'fine' },
              'state: counterexample (cycle descendant)');
}

done_testing();
