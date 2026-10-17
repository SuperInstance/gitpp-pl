package Gitpp;
# gitpp-pl — Perl 5 port of the git.pp fold
# Doc-only discipline: written from git.pp-spec v0.3.0 alone.
use strict;
use warnings;
use B ();
use utf8;
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use Scalar::Util qw(looks_like_number);


# Custom JSON encoder per spec §2:
# - {effects, id, kind, parents, reason} with keys in this order
# - ', ' and ': ' as separators
# - Literal Unicode (no \\uXXXX escapes)
# - Object keys sorted by Unicode code point

# Rewrite bare integer literals that exceed a 64-bit IV so JSON::PP decodes
# them as float64 rather than promoting them to a string.
#
# WHY THIS EXISTS. Spec §2/§3 put every JSON number in the float64 domain,
# but JSON::PP does not. An integer literal too large for a UV/IV is
# returned as a plain STRING, and a JSON string must stay a string, so the
# information is already gone by the time we see the decoded structure --
# no amount of inspection recovers it. The fix therefore has to happen on
# the TEXT, before decoding.
#
# Appending ".0" to such a literal makes JSON::PP produce a proper NV,
# which is what the spec asks for. A quoted string is untouched, because
# the scanner never enters a string literal. Small integers are untouched
# too: they are already exact in an IV and every port agrees on them.
#
# "724818294626474393600" (a string) and 724818294626474393600 (a number)
# must stay different records, and this scan is the only place that
# distinction still exists. (gitpp-pl v0.1.9)
sub _widen_large_int_literals {
    my ($text) = @_;
    my $out = "";
    my $i   = 0;
    my $n   = length $text;
    my $BS  = chr(92);
    my $is_digit = sub { my $c = substr($text, $_[0], 1); $c ge "0" && $c le "9" };

    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq '"') {
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($text, $j, 1);
                if ($d eq $BS) { $j += 2; next; }
                last if $d eq '"';
                $j++;
            }
            $out .= substr($text, $i, $j - $i + 1);
            $i = $j + 1;
            next;
        }
        if ($c eq "-" || $is_digit->($i)) {
            my $j = $i;
            $j++ if substr($text, $j, 1) eq "-";
            my $ds = $j;
            $j++ while $j < $n && $is_digit->($j);
            my $ndigits = $j - $ds;
            my $int_only = 1;
            if ($j < $n && substr($text, $j, 1) eq ".") {
                $int_only = 0; $j++;
                $j++ while $j < $n && $is_digit->($j);
            }
            if ($j < $n && (substr($text, $j, 1) eq "e" || substr($text, $j, 1) eq "E")) {
                $int_only = 0; $j++;
                $j++ if $j < $n && (substr($text, $j, 1) eq "+" || substr($text, $j, 1) eq "-");
                $j++ while $j < $n && $is_digit->($j);
            }
            my $lit = substr($text, $i, $j - $i);
            $out .= ($int_only && $ndigits >= 16) ? $lit . ".0" : $lit;
            $i = $j;
            next;
        }
        $out .= $c;
        $i++;
    }
    return $out;
}


# Decode a record set with every number in the float64 domain (spec §2/§3).
#
# The widening must happen on the TEXT: by the time JSON::PP hands back a
# structure, a too-large integer literal is already a string, and a JSON
# string must stay a string. Callers should use this rather than
# decode_json, which does not widen.
sub decode_records {
    my ($text) = @_;
    return JSON::PP->new->utf8(0)->decode(_widen_large_int_literals($text));
}

sub canonical_json {
    my ($v) = @_;
    return _emit($v, ", ", ": ");
}


# True iff $v is a JSON NUMBER (not a string that merely looks numeric).
# B is core Perl, so this keeps the port stdlib-only.
sub _is_json_number {
    my ($v) = @_;
    return 0 if ref $v;
    my $flags = B::svref_2object(\$v)->FLAGS;
    return 0 if $flags & B::SVp_POK();          # POK => it is (also) a string
    return (($flags & B::SVp_IOK()) || ($flags & B::SVp_NOK())) ? 1 : 0;
}

sub _emit {
    my ($v, $sep, $kv) = @_;
    if (!defined $v) { return "null"; }
    if (ref($v) eq 'HASH') {
        my @parts;
        for my $k (sort { code_point_cmp($a, $b) } keys %$v) {
            push @parts, _string($k) . $kv . _emit($v->{$k}, $sep, $kv);
        }
        return "{" . join($sep, @parts) . "}";
    }
    if (ref($v) eq 'ARRAY') {
        my @parts;
        for my $item (@$v) {
            push @parts, _emit($item, $sep, $kv);
        }
        return "[" . join($sep, @parts) . "]";
    }
    if (ref($v) eq 'JSON::PP::Boolean') {
        return $v ? "true" : "false";
    }
    if (ref($v)) { return 'null'; }
    # Number handling per spec §3.
    #
    # This MUST test the SV's numeric flags, not looks_like_number(). JSON::PP
    # hands back a plain scalar for both `1.5e20` and the STRING "1.5e20", and
    # looks_like_number() is true for both -- so the old test emitted a numeric
    # string unquoted (`{"x": 1.5e20}`), silently turning a string into a
    # number and changing the leaf. Spec §3 says strings are "unchanged".
    # (gitpp-pl v0.1.6)
    if (_is_json_number($v)) {
        # Cover 0, 0.0, -0.0
        if ($v == 0) {
            return "0";
        }
        my $abs = abs($v);
        # Integer that fits in int64 (< 1e16). Larger integer-valued
        # floats fall through to scientific notation (matches what C#
        # and C do, since the long cast would overflow).
        # The integer check uses both regex AND arithmetic to be safe:
        # JSON::PP may parse "-323443252343067.94" as the rounded double
        # -323443252343068 (no decimal in string form), so the regex
        # matches but the value is "non-integer" in the original input.
        # We treat the value as integer only if $v == int($v).
        if ($v == int($v) && $abs < 1e16) {
            return int($v);
        }
        # Non-integral: scientific when |v| < 1e-4 or |v| >= 1e16
        # Use 15-digit precision (Python's "short" repr), fall back to
        # 16 then 17 if 15 doesn't round-trip. Matches Python repr().
        my $s;
        my $found = 0;
        for my $d (15, 16, 17) {
            $s = sprintf("%.${d}g", $v);
            if ($s + 0 != $v) { next; }
            if ($abs >= 1e16 && $s !~ /e/i) { next; }
            $found = 1;
            last;
        }
        if (!$found) {
            $s = sprintf("%.16e", $v);
            $s =~ s/0+e/e/;
            $s =~ s/\.e/e/;
        }
        if ($abs < 1e-4 || $abs >= 1e16) {
            if ($s =~ /^([^e]+)e([+-]?\d+)$/i) {
                my $m = $1;
                my $e = int($2);
                my $exp_str = sprintf("%02d", abs($e));
                if ($e < 0) {
                    return "$m" . "e-$exp_str";
                } else {
                    return "$m" . "e+$exp_str";
                }
            }
            return $s;
        }
        return $s;
    }
    return _string($v);
}

sub _string {
    my ($s) = @_;
    $s = "" if !defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\f/\\f/g;
    $s =~ s/\x08/\\b/g;
    return '"' . $s . '"';
}

sub code_point_cmp {
    my ($lhs, $rhs) = @_;
    return 0 if !defined $lhs && !defined $rhs;
    return -1 if !defined $lhs;
    return 1  if !defined $rhs;
    my @L = unpack("U*", $lhs);
    my @R = unpack("U*", $rhs);
    my $n = @L < @R ? @L : @R;
    for my $i (0 .. $n - 1) {
        my ($x, $y) = ($L[$i], $R[$i]);
        next if $x == $y;
        return $x < $y ? -1 : 1;
    }
    # one is a prefix of the other: the shorter sorts first
    return @L <=> @R;
}



# Build a record leaf per the spec §2.
sub record_leaf {
    my ($record) = @_;
    my $parents = [sort { code_point_cmp($a, $b) } @{$record->{parents} || []}];
    my $canon = {
        effects => $record->{effects} || {},
        id      => $record->{id},
        kind    => $record->{kind} // undef,
        parents => $parents,
        reason  => $record->{reason} // undef,
    };
    my $json = canonical_json($canon);
    require Encode;
    return sha256_hex(Encode::encode_utf8($json));
}

# Compute the closure root at <at>
sub closure_root {
    my ($records, $at) = @_;
    my %by_id = map { $_->{id} => $_ } grep { $_->{id} } @$records;
    return (undef, undef) unless exists $by_id{$at};

    my %seen;
    my @stack = ($at);
    while (@stack) {
        my $cur = pop @stack;
        next if $seen{$cur};
        return (undef, undef) unless exists $by_id{$cur};
        $seen{$cur} = 1;
        for my $p (@{$by_id{$cur}{parents} || []}) {
            push @stack, $p unless $seen{$p};
        }
    }

    my @sorted = sort { code_point_cmp($a, $b) } keys %seen;
    my @lines = map { "$_:" . record_leaf($by_id{$_}) } @sorted;
    my $joined = join("\n", @lines);
    return (sha256_hex(Encode::encode_utf8($joined)), \@sorted);
}

# Detect cycle via DFS
sub _find_cycles {
    my (%by_id) = @_;
    my %color;
    my %cycle;
    my $dfs;
    $dfs = sub {
        my ($rid, $path) = @_;
        my $c = $color{$rid} // 0;
        if ($c == 1) {
            my $idx = 0;
            $idx++ while $path->[$idx] ne $rid;
            for my $i ($idx .. $#{$path}) {
                $cycle{$path->[$i]} = 1;
            }
            return;
        }
        return if $c == 2;
        $color{$rid} = 1;
        push @{$path}, $rid;
        for my $p (@{$by_id{$rid}{parents} || []}) {
            $dfs->($p, $path) if exists $by_id{$p};
        }
        pop @$path;
        $color{$rid} = 2;
    };
    for my $rid (keys %by_id) {
        $dfs->($rid, []) if ($color{$rid} // 0) == 0;
    }
    return %cycle;
}

# The fold: returns {state, order, conflicts, orphans}

# Structural key for an effects value: two records "agree" on a key iff their
# values serialize identically. Hashes sort their keys, so key order never
# counts as a difference.
#
# IMPORTANT: this never touches the caller's SV. Anything that stringifies a
# value (sprintf, join, string concat) adds SVp_POK to the *aliased* SV in
# Perl, which would make a genuine JSON number look like a string to the
# encoder downstream. Hence the explicit copy in the scalar branch.
sub _value_key {
    my ($v) = @_;
    return 'null' if !defined $v;
    if (ref($v) eq 'HASH') {
        return '{' . join(',', map { canonical_json($_) . ':' . _value_key($v->{$_}) }
                             sort { code_point_cmp($a, $b) } keys %$v) . '}';
    }
    if (ref($v) eq 'ARRAY') {
        return '[' . join(',', map { _value_key($_) } @$v) . ']';
    }
    if (ref($v) eq 'JSON::PP::Boolean') {
        return $v ? 'true' : 'false';
    }
    my $copy = $v;          # copy: stringify the copy, never the original
    return canonical_json($copy);
}

sub derive {
    my ($records) = @_;
    my %by_id = map { $_->{id} => $_ } grep { $_->{id} } @$records;

    my %orphans;
    for my $r (@$records) {
        next unless $r->{id};
        for my $p (@{$r->{parents} || []}) {
            unless (exists $by_id{$p}) {
                $orphans{$r->{id}} = 1;
                last;
            }
        }
    }
    my %cycle = _find_cycles(%by_id);
    my %all_orphans = (%orphans, %cycle);
    my %applied = map { $_->{id} => $_ } grep { $_->{id} && !$all_orphans{$_->{id}} } @$records;

    # Topo sort
    my %in_deg = map { $_ => 0 } keys %applied;
    my %children = map { $_ => [] } keys %applied;
    for my $rid (keys %applied) {
        for my $p (@{$applied{$rid}{parents} || []}) {
            if (exists $applied{$p}) {
                push @{$children{$p}}, $rid;
                $in_deg{$rid}++;
            }
        }
    }
    my @queue = sort { code_point_cmp($a, $b) } grep { $in_deg{$_} == 0 } keys %applied;
    my @order;
    while (@queue) {
        my $rid = shift @queue;
        push @order, $rid;
        for my $child (sort { code_point_cmp($a, $b) } @{$children{$rid}}) {
            $in_deg{$child}--;
            if ($in_deg{$child} == 0) {
                push @queue, $child;
                @queue = sort { code_point_cmp($a, $b) } @queue;
            }
        }
    }

    # Apply effects with class precedence
    my %state;       # key -> {value, set_by, kind}
    my %setters;    # spec §5.6: key -> record id that set it
    my %setter;      # key -> rid
    my %conflict;    # key -> {winner, losers}
    my %precedence = (override => 3, task => 2, witness => 1);

    my $is_descendant = sub {
        my ($ancestor, $descendant) = @_;
        return 0 if $ancestor eq $descendant;
        my %seen;
        my @stack = ($descendant);
        while (@stack) {
            my $cur = pop @stack;
            next if $seen{$cur}++;
            next unless exists $applied{$cur};
            for my $p (@{$applied{$cur}{parents} || []}) {
                return 1 if $p eq $ancestor;
                push @stack, $p;
            }
        }
        return 0;
    };

    for my $rid (@order) {
        my $r = $applied{$rid};
        for my $k (keys %{$r->{effects} || {}}) {
            my $v = $r->{effects}{$k};
            if (exists $state{$k}) {
                my $existing_kind = $applied{$setter{$k}}{kind};
                my $new_kind = $r->{kind};
                if (($precedence{$new_kind} // 0) > ($precedence{$existing_kind} // 0)) {
                    if (!exists $conflict{$k}) {
                        $conflict{$k} = { winner => $rid, losers => [] };
                    } else {
                        $conflict{$k}{winner} = $rid;
                    }
                    push @{$conflict{$k}{losers}}, $setter{$k};
                    $state{$k} = { value => $v, set_by => $rid, kind => $new_kind };
                    $setter{$k} = $rid;
                    $setters{$k} = $rid;
                } elsif (($precedence{$new_kind} // 0) == ($precedence{$existing_kind} // 0)) {
                    if ($is_descendant->($setter{$k}, $rid)) {
                        if (!exists $conflict{$k}) {
                            $conflict{$k} = { winner => $rid, losers => [] };
                        } else {
                            $conflict{$k}{winner} = $rid;
                        }
                        push @{$conflict{$k}{losers}}, $setter{$k};
                        $state{$k} = { value => $v, set_by => $rid, kind => $new_kind };
                        $setter{$k} = $rid;
                        $setters{$k} = $rid;
                    } else {
                        if (!exists $conflict{$k}) {
                            $conflict{$k} = { winner => $setter{$k}, losers => [] };
                        }
                        push @{$conflict{$k}{losers}}, $rid;
                    }
                } else {
                    if (!exists $conflict{$k}) {
                        $conflict{$k} = { winner => $setter{$k}, losers => [] };
                    }
                    push @{$conflict{$k}{losers}}, $rid;
                }
            } else {
                $state{$k} = { value => $v, set_by => $rid, kind => $r->{kind} };
                $setter{$k} = $rid;
                $setters{$k} = $rid;
            }
        }
    }

    # Per spec §5.3: a conflict is emitted only when 2+ DISTINCT values exist
    # for k across ALL candidates, and `losers` is every candidate that set k
    # with a value OTHER THAN the winner's. The streaming loop above records a
    # loser the moment one outranks another, which over-reports when two
    # records agree. Reconcile here. (gitpp-pl v0.1.5)
    my %vals;
    for my $rid (keys %applied) {
        my $e = $applied{$rid}{effects} || {};
        for my $k (keys %$e) {
            push @{ $vals{$k} }, _value_key($e->{$k});
        }
    }
    for my $k (keys %conflict) {
        my $all = $vals{$k} || [];
        my %uniq = map { $_ => 1 } @$all;
        if (scalar(keys %uniq) < 2) { delete $conflict{$k}; next; }
        my $w = $conflict{$k}{winner};
        my $wv = $w && $applied{$w} ? _value_key($applied{$w}{effects}{$k}) : undef;
        $conflict{$k}{losers} = [ grep {
            $_ ne $w && $applied{$_} && _value_key($applied{$_}{effects}{$k}) ne $wv
        } @{ $conflict{$k}{losers} } ];
        if (!@{ $conflict{$k}{losers} }) { delete $conflict{$k}; next; }
    }

    return {
        state => { map { $_ => $state{$_}{value} } keys %state },
        # Spec §5.6: setter for every key, not only contested ones. The fold
        # computed this in $setter and discarded it, which left a same-class
        # nudge parented on the wrong record landing or vanishing depending
        # only on whether its own id sorted before the winner's.
        setters => { map { $_ => $setters{$_} } grep { defined $setters{$_} } keys %state },
        order => \@order,
        conflicts => [ map { { key => $_, winner => $conflict{$_}{winner}, losers => $conflict{$_}{losers} } } sort { code_point_cmp($a, $b) } keys %conflict ],
        orphans => [ sort { code_point_cmp($a, $b) } keys %all_orphans ],
    };
}

sub fold_with_closure {
    my ($records, $at) = @_;
    my $d = derive($records);
    my ($root, $closure) = closure_root($records, $at);
    return {
        state => $d->{state},
        order => $d->{order},
        conflicts => $d->{conflicts},
        orphans => $d->{orphans},
        closure => $closure,
        closureRoot => $root,
    };
}

1;
