# CLANK-WIT: name=Local
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Local data provider: searches wiki, diary, journal, discoveries, rollodex
# CLANK-WIT: usage=Input: { action: "search", query: "Alice", limit: 10 } Output: { results: [{ content, provenance }] }
# CLANK-WIT: hint=search_local, local search, wiki, diary, rollodex, user data
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Search::Local;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_local',
        description => 'Local data provider: searches wiki, diary, journal, discoveries, rollodex',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 5 },
                sources => { type => 'array', items => { type => 'string' }, description => 'Sources to search' },
            },
            required => ['action', 'query'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{sources} //= [
                { name => 'rollodex', topic => 'user.rollodex.search', fields => [qw(name relation email phone note)] },
                { name => 'diary',    topic => 'user.diary.search',    fields => [qw(content mood tags)] },
                { name => 'journal',  topic => 'user.journal.search',  fields => [qw(summary tags)] },
                { name => 'wiki',     topic => 'wiki.search',          fields => [qw(title content tags)] },
                { name => 'discoveries', topic => 'user.discoveries.search', fields => [qw(topic detail tags)] },
                { name => 'family',   topic => 'user.family.search',   fields => [qw(name relation notes)] },
                { name => 'patterns', topic => 'user.patterns.search', fields => [qw(pattern category)] },
            ];

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                my $sources = $args->{sources} // [];
                return { error => "No query" } unless $query;

                my @active = @$sources ? grep { my $n = $_->{name}; grep { $n =~ /$_/ } @$sources } @{$state->{sources}} : @{$state->{sources}};

                my @results;
                my $bus = $ctx{bus};

                for my $src (@active) {
                    next unless $bus;
                    my $res = eval { $bus->publish($src->{topic}, { action => 'search', query => $query, limit => $limit }) };
                    next unless ref $res eq 'HASH';

                    my @items;
                    if (ref $res->{entries} eq 'ARRAY') { @items = @{$res->{entries}}; }
                    elsif (ref $res->{matches} eq 'ARRAY') { @items = @{$res->{matches}}; }
                    elsif (ref $res->{results} eq 'ARRAY') { @items = @{$res->{results}}; }
                    elsif (ref $res->{patterns} eq 'ARRAY') { @items = @{$res->{patterns}}; }
                    next unless @items;

                    for my $item (@items[0..($limit > $#items ? $#items : $limit-1)]) {
                        my $content = $item->{content} // $item->{detail} // $item->{summary} // $item->{note} // '';
                        $content = join(' ', @{$item->{notes}}) if ref $item->{notes} eq 'ARRAY' && !$content;
                        next unless $content;

                        my $ref = $item->{id} // $item->{name};
                        push @results, {
                            content     => $content,
                            text        => $content,
                            _provider   => "local.$src->{name}",
                            _weight     => 0.8,
                            _timestamp  => $item->{time} // $item->{created} // time(),
                            _url        => '',
                            _ref        => defined($ref) ? "$src->{name}:$ref" : $src->{name},
                            _score      => 0.7,
                        };
                    }
                }

                return { topic => 'search.local.results', results => \@results };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
