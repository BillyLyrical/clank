# CLAM-WIT: name=Search
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=General-purpose context gatherer: parallel search across pluggable providers
# CLAM-WIT: usage=Input: { action: "search", query: "how to fix Perl IPC" } or { action: "register", provider: "web", weight: 0.3 } or { action: "providers" } Output: { results: [...], count, cached }
# CLAM-WIT: hint=search, search orchestrator, providers, fan-out, merge, rank, dedup
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Search::Search;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search',
        description => 'General-purpose context gatherer: parallel search across pluggable providers',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, register, unregister, providers, cache_clear' },
                query   => { type => 'string', description => 'Search query' },
                sources => { type => 'array', items => { type => 'string' }, description => 'Sources to search' },
                types   => { type => 'array', items => { type => 'string' }, description => 'Result types' },
                limit   => { type => 'integer', description => 'Max results', default => 10 },
                force   => { type => 'boolean', description => 'Bypass cache' },
                provider => { type => 'string', description => 'Provider name (for register/unregister)' },
                weight  => { type => 'number', description => 'Provider weight (for register)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};
            my $bus = $ctx{bus};

            $state->{providers} //= {};
            $state->{cache} //= {};
            $state->{default_ttl} //= 1800;
            $state->{query_log} //= [];

            if ($action eq 'register') {
                my $name = $args->{provider} // '';
                my $weight = $args->{weight} // 0.5;
                my $ttl = $args->{ttl} // $state->{default_ttl};
                my $types = $args->{types} // ['all'];
                my $topic = $args->{topic} // "search.$name";
                return { error => "No provider" } unless $name;

                $state->{providers}{$name} = {
                    name   => $name,
                    weight => $weight,
                    ttl    => $ttl,
                    types  => $types,
                    topic  => $topic,
                    active => 1,
                };
                return { topic => 'search.registered', provider => $name };
            }

            if ($action eq 'unregister') {
                my $name = $args->{provider} // '';
                delete $state->{providers}{$name};
                return { topic => 'search.unregistered', provider => $name };
            }

            if ($action eq 'providers') {
                return { topic => 'search.providers', providers => [sort keys %{$state->{providers}}] };
            }

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $sources = $args->{sources} // [];
                my $types = $args->{types} // [];
                my $limit = $args->{limit} // 10;
                my $force = $args->{force} // 0;
                return { error => "No query" } unless $query;

                my $ck = _cache_key($query, $sources, $types);
                if (!$force && $state->{cache}{$ck}) {
                    my $c = $state->{cache}{$ck};
                    if (time() - $c->{time} < ($c->{ttl} // $state->{default_ttl})) {
                        return { topic => 'search.results', results => $c->{results}, cached => 1, age => time() - $c->{time} };
                    }
                    delete $state->{cache}{$ck};
                }

                my @active = grep { $_->{active} } values %{$state->{providers}};
                @active = grep { my $n = $_->{name}; grep { $n =~ /$_/ } @$sources } @active if @$sources;
                @active = grep { my $t = $_->{types}; !@$types || grep { my $x = $_; grep { $x eq $_ || $_ eq 'all' } @$t } @$types } @active if @$types;

                my @all;
                for my $p (@active) {
                    my $results = eval { $bus ? $bus->publish($p->{topic}, { query => $query, limit => $limit }) : undef };
                    next unless ref $results eq 'HASH' && ref $results->{results} eq 'ARRAY';
                    for my $r (@{$results->{results}}) {
                        $r->{_provider} = $p->{name};
                        $r->{_weight} = $p->{weight};
                    }
                    push @all, @{$results->{results}};
                }

                @all = _rank(\@all);
                @all = _dedup(\@all);
                @all = @all[0..$limit-1] if @all > $limit;

                for my $r (@all) {
                    $r->{provenance} = {
                        provider  => $r->{_provider} // 'unknown',
                        timestamp => $r->{_timestamp} // time(),
                        url       => $r->{_url} // '',
                        ref       => $r->{_ref} // '',
                        score     => $r->{_final_score} // 0,
                    };
                    delete $r->{_provider};
                    delete $r->{_weight};
                    delete $r->{_score};
                    delete $r->{_timestamp};
                    delete $r->{_url};
                    delete $r->{_ref};
                    delete $r->{_final_score};
                }

                my $ttl = $state->{default_ttl};
                for my $p (@active) { $ttl = $p->{ttl} if $p->{ttl} < $ttl; }
                $state->{cache}{$ck} = { results => \@all, time => time(), ttl => $ttl };

                push @{$state->{query_log}}, { query => $query, results => scalar @all, time => time() };
                $state->{query_log} = [@{$state->{query_log}}[-100..-1]] if @{$state->{query_log}} > 100;

                return {
                    topic   => 'search.results',
                    results => \@all,
                    count   => scalar @all,
                    cached  => 0,
                    sources => [map { $_->{name} } @active],
                };
            }

            if ($action eq 'cache_clear') {
                my $query = $args->{query} // '';
                if ($query) { delete $state->{cache}{_cache_key($query, [], [])}; }
                else { $state->{cache} = {}; }
                return { topic => 'search.cache_cleared', all => !$query };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _cache_key {
    my ($q, $src, $typ) = @_;
    require Digest::MD5;
    return Digest::MD5::md5_hex($q . '|' . join(',', sort @$src) . '|' . join(',', sort @$typ));
}

sub _rank {
    my ($results) = @_;
    for my $r (@$results) {
        my $rel = $r->{_score} // 0.5;
        my $w = $r->{_weight} // 0.5;
        my $rec = 1.0;
        if ($r->{_timestamp}) {
            $rec = 1.0 / (1.0 + (time() - $r->{_timestamp}) / 86400);
        }
        $r->{_final_score} = $rel * 0.5 + $rec * 0.3 + $w * 0.2;
    }
    return sort { $b->{_final_score} <=> $a->{_final_score} } @$results;
}

sub _dedup {
    my ($results) = @_;
    my (@seen, @out);
    for my $r (@$results) {
        my $sig = substr($r->{content} // $r->{text} // '', 0, 100);
        my $dup = 0;
        for my $s (@seen) {
            my @wa = split /\s+/, lc($sig);
            my @wb = split /\s+/, lc($s);
            my %c; $c{$_} = 1 for grep { my $w = $_; grep { $w eq $_ } @wb } @wa;
            my $tot = @wa + @wb - scalar keys %c;
            $dup = 1 if $tot > 0 && scalar(keys %c) / $tot > 0.7;
        }
        unless ($dup) { push @seen, $sig; push @out, $r; }
    }
    return @out;
}

1;
