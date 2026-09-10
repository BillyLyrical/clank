# CLANK-WIT: name=SearchFirst
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Research-before-coding: check repo, CPAN, and web for existing solutions before building
# CLANK-WIT: usage=Input: { description: "IPC mechanism for parent-child comm", language?: "perl", constraints?: "must be async" } Output: { channels_checked: [...], candidates: [...], decision: "adopt"|"extend"|"compose"|"build", rationale: "..." }
# CLANK-WIT: hint=search first, research before coding, existing solutions, CPAN, avoid reinventing, adopt extend compose build
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Search::SearchFirst;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_first',
        description => 'Research existing solutions before implementing: checks repo, CPAN, and web',
        parameters  => {
            type       => 'object',
            properties => {
                description => { type => 'string', description => 'What you want to build or solve' },
                language    => { type => 'string', description => 'Target language (default: perl)' },
                constraints => { type => 'string', description => 'Additional constraints or requirements' },
            },
            required => ['description'],
        },
        execute => sub {
            my ($args) = @_;
            my $desc = $args->{description} // '';
            my $lang = $args->{language} // 'perl';
            my $constraints = $args->{constraints} // '';
            return { error => 'No description provided' } unless $desc;

            my @keywords = _extract_keywords($desc);
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $bus = $ctx{bus};

            my @channels_checked;
            my @candidates;

            # Channel 1: repo search via rg
            my $repo_result = _check_repo(\@keywords);
            push @channels_checked, $repo_result->{channel};
            push @candidates, @{$repo_result->{candidates}};

            # Channel 2: CPAN / package registry
            my $cpan_result = _check_cpan(\@keywords, $lang);
            push @channels_checked, $cpan_result->{channel};
            push @candidates, @{$cpan_result->{candidates}};

            # Channel 3: web search if available
            my $web_result = _check_web(\@keywords, $bus);
            push @channels_checked, $web_result->{channel};
            push @candidates, @{$web_result->{candidates}};

            # Score and rank candidates
            @candidates = sort { $b->{score} <=> $a->{score} } @candidates;

            # Make decision
            my ($decision, $rationale) = _decide(\@candidates);

            return {
                channels_checked => \@channels_checked,
                candidates       => \@candidates,
                decision         => $decision,
                rationale        => $rationale,
            };
        },
    );
}

sub _extract_keywords {
    my ($desc) = @_;
    my @stop = qw(a an the is are was were be been being have has had do does did
        will would shall should may might can could of in to for on with at by
        from as into through during before after above below between out off
        over under again further then once that this these those it its);
    my @words = split /\W+/, lc($desc);
    my %seen;
    my %stop = map { $_ => 1 } @stop;
    return grep { length($_) > 2 && !$seen{$_}++ && !$stop{$_} } @words;
}

sub _check_repo {
    my ($keywords) = @_;
    my @found;

    my @search_dirs;
    push @search_dirs, 'lib' if -d 'lib';
    push @search_dirs, 't' if -d 't';
    push @search_dirs, 'src' if -d 'src';
    @search_dirs = ('lib') unless @search_dirs;

    for my $dir (@search_dirs) {
        for my $kw (@$keywords) {
            my $out = `rg -l -i "$kw" $dir 2>/dev/null`;
            next unless $out;
            for my $file (split /\n/, $out) {
                next unless $file =~ /\.p[lm]$|\.t$/;
                my $content = `rg -i -C2 "$kw" "$file" 2>/dev/null`;
                my $score = 0.7;
                my $match_count = () = $content =~ /$kw/gi;
                $score += 0.1 if $match_count > 3;
                push @found, {
                    name          => $file,
                    source        => 'repo',
                    score         => $score,
                    recommendation => 'adopt',
                    match_preview => (split /\n/, $content)[0] // '',
                };
            }
        }
    }

    my $available = scalar @search_dirs > 0;
    return {
        channel    => { name => 'repo', available => $available, result => scalar(@found) . ' matches found' },
        candidates => \@found,
    };
}

sub _check_cpan {
    my ($keywords, $lang) = @_;
    my @found;

    if ($lang eq 'perl') {
        # Try perldoc for common module patterns
        for my $kw (@$keywords) {
            my $module = join('::', map { ucfirst($_) } split /[_\-]/, $kw);
            my $out = `perldoc -l $module 2>/dev/null`;
            if ($out && $? == 0) {
                chomp $out;
                push @found, {
                    name          => $module,
                    source        => 'cpan',
                    score         => 0.8,
                    recommendation => 'adopt',
                    path          => $out,
                };
            }
        }

        # Also try MetaCPAN API if keywords yield no direct matches
        unless (@found) {
            my $query = join('+', @$keywords[0..($#$keywords > 2 ? 2 : $#$keywords)]);
            my $out = `curl -s "https://fastapi.metacpan.org/v1/module/_search?q=$query&size=3" 2>/dev/null`;
            if ($out) {
                eval {
                    require JSON::PP;
                    my $data = JSON::PP::decode_json($out);
                    for my $hit (@{$data->{hits}{hits} // []}) {
                        my $name = $hit->{_source}{module}[0]{name} // $hit->{_id} // '';
                        next unless $name;
                        push @found, {
                            name          => $name,
                            source        => 'cpan',
                            score         => 0.6,
                            recommendation => 'extend',
                            description   => $hit->{_source}{abstract} // '',
                        };
                    }
                };
            }
        }
    }

    my $available = $lang eq 'perl';
    return {
        channel    => { name => 'cpan', available => $available, result => scalar(@found) . ' modules found' },
        candidates => \@found,
    };
}

sub _check_web {
    my ($keywords, $bus) = @_;
    my @found;

    my $available = defined $bus;
    return {
        channel    => { name => 'web', available => $available, result => $available ? 'search pending' : 'no bus available' },
        candidates => \@found,
    } unless $available;

    my $query = join(' ', @$keywords) . ' solution implementation';
    my $results = eval {
        $bus->publish('search.web', { query => $query, limit => 5 })
    };

    if (ref $results eq 'HASH' && ref $results->{results} eq 'ARRAY') {
        for my $r (@{$results->{results}}) {
            my $title = $r->{title} // $r->{text} // '';
            my $score = 0.4;
            $score += 0.1 if $r->{url} && $r->{url} =~ /github\.com|metacpan\.org|perl\.org/;
            push @found, {
                name          => $title,
                source        => 'web',
                score         => $score,
                recommendation => 'compose',
                url           => $r->{url} // '',
            };
        }
    }

    return {
        channel    => { name => 'web', available => 1, result => scalar(@found) . ' results found' },
        candidates => \@found,
    };
}

sub _decide {
    my ($candidates) = @_;
    return ('build', 'No candidates found in any channel') unless @$candidates;

    my $best = $candidates->[0];

    if ($best->{score} >= 0.8) {
        return ('adopt', "Strong match found: $best->{name} ($best->{source}, score $best->{score})");
    }
    if ($best->{score} >= 0.6) {
        return('extend', "Partial match found: $best->{name} ($best->{source}, score $best->{score}) - may need extension");
    }
    if (@$candidates >= 2 && $candidates->[0]{score} + $candidates->[1]{score} >= 1.0) {
        return ('compose', "Multiple partial matches: $candidates->[0]{name} + $candidates->[1]{name} - composition possible");
    }
    if ($best->{score} >= 0.3) {
        return ('build', "Weak matches exist but none strong enough: best was $best->{name} ($best->{score})");
    }
    return ('build', "No meaningful matches found in checked channels");
}

1;
