package Gitpp;
# gitpp-pl — Perl 5 port of the git.pp fold
# Doc-only discipline: written from git.pp-spec v0.3.0 alone.
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use Scalar::Util qw(looks_like_number);


# Custom JSON encoder per spec §2:
# - {effects, id, kind, parents, reason} with keys in this order
# - ', ' and ': ' as separators
# - Literal Unicode (no \\uXXXX escapes)
# - Object keys sorted by Unicode code point
sub canonical_json {
    my ($v) = @_;
    return _emit($v, ", ", ": ");
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
    # Number handling per spec §3. Use looks_like_number so "task-1"
    # doesn't match the numeric check.
    if (looks_like_number($v)) {
        # Cover 0, 0.0, -0.0
        if ($v == 0) {
            return "0";
        }
        my $abs = abs($v);
        # Integer that fits in int64 (< 1e16). Larger integer-valued
        # floats fall through to scientific notation (matches what C#
        # and C do, since the long cast would overflow).
        if ($v =~ /^-?\d+$/ && $abs < 1e16) {
            return "$v";
        }
        # Non-integral: scientific when |v| < 1e-4 or |v| >= 1e16
        # Use 15-digit precision (Python's "short" repr), fall back to
        # 16 then 17 if 15 doesn't round-trip. Matches Python repr().
        my $digits = 15;
        my $s = sprintf("%.${digits}g", $v);
        if ($s + 0 != $v) {
            # 15 digits didn't round-trip; try 16
            $digits = 16;
            $s = sprintf("%.${digits}g", $v);
            if ($s + 0 != $v) {
                # Still didn't; fall back to 17
                $digits = 17;
                $s = sprintf("%.${digits}g", $v);
            }
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
    my @a = unpack("U*", $a);
    my @b = unpack("U*", $b);
    for my $i (0 .. $#a) {
        return -1 if $i > $#b;
        return 1 if $i > $#a;
        return -1 if $a[$i] < $b[$i];
        return 1 if $a[$i] > $b[$i];
    }
    return 0;
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
            }
        }
    }

    return {
        state => { map { $_ => $state{$_}{value} } keys %state },
        order => \@order,
        conflicts => [ map { { key => $_, winner => $conflict{$_}{winner}, losers => $conflict{$_}{losers} } } keys %conflict ],
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
