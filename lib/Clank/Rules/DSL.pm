# Clank::Rules::DSL — lightweight rule syntax that compiles to Perl closures.
# Users write:   when <pattern> → <action>
# Engine stores: Clank::Rules::Rule objects with code refs.
#
# Format:
#   rule <name> [priority <N>] [domain <D>]
#     when <regex or /regex/flags or plain string>
#     then <action>            (repeatable)
#     end
# Actions: domain <D>, tag <T>, mode <M>, set <K> <V>, output <T>
package Clank::Rules::DSL;
use strict;
use warnings;
require Clank::Rules::Rule;

# Parse a DSL string into an arrayref of Clank::Rules::Rule.
sub parse {
    my ($class, $text) = @_;
    my @rules;
    my @lines = split /\n/, $text;
    my ($name, $priority, $domain, $pattern, @actions);

    for my $line (@lines) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless $line;

        if ($line =~ /^rule\s+(\w+)/) {
            # Flush previous rule.
            if ($name) {
                push @rules, _build_rule($name, $priority, $domain, $pattern, \@actions);
            }
            $name     = $1;
            $priority = 0;
            $domain   = undef;
            $pattern  = undef;
            @actions  = ();
            $priority = $1 if $line =~ /priority\s+(\d+)/;
            $domain   = $1 if $line =~ /domain\s+(\w+)/;
        }
        elsif ($line =~ /^when\s+(.+)/) {
            $pattern = $1;
        }
        elsif ($line =~ /^then\s+(.+)/) {
            push @actions, $1;
        }
        elsif ($line =~ /^end/) {
            if ($name) {
                push @rules, _build_rule($name, $priority, $domain, $pattern, \@actions);
                ($name, $priority, $domain, $pattern, @actions) = ();
            }
        }
    }
    # Flush last rule.
    push @rules, _build_rule($name, $priority, $domain, $pattern, \@actions) if $name;

    return \@rules;
}

# Compile a DSL rule into a Clank::Rules::Rule with a closure action.
sub _build_rule {
    my ($name, $priority, $domain, $pattern_str, $actions) = @_;
    # Copy the actions: parse() reuses one array for every rule and clears it
    # at each 'end', so capturing the reference would leave every closure empty.
    my @acts = @$actions;

    # Compile pattern to regex. /.../ (with optional flags) is a real regex;
    # anything else is matched as a literal string.
    my $match;
    if ($pattern_str) {
        if ($pattern_str =~ m{^/(.+)/([imsx]*)$}) {
            my ($pat, $flags) = ($1, $2);
            $match = eval 'qr{' . $pat . '}' . $flags;
        }
        $match = eval "qr{\\Q$pattern_str\\E}" unless $match;
    }

    # Compile actions to a closure.
    my $action_sub = sub {
        my ($context) = @_;
        my $result = { domain => $domain // 'general' };
        for my $act (@acts) {
            if ($act =~ /^domain\s+(\w+)/) {
                $result->{domain} = $1;
            }
            elsif ($act =~ /^tag\s+(.+)/) {
                push $result->{tags}->@*, $1;
            }
            elsif ($act =~ /^mode\s+(\w+)/) {
                $result->{mode} = $1;
            }
            elsif ($act =~ /^set\s+(\w+)\s+(.+)/) {
                $result->{$1} = $2;
            }
            elsif ($act =~ /^output\s+(.+)/) {
                $result->{output} = $1;
            }
            elsif ($act =~ /^inject\s+(.+)/) {
                push $result->{inject}->@*, $1;
            }
        }
        return $result;
    };

    return Clank::Rules::Rule->new(
        name     => $name,
        type     => 'pattern',
        priority => $priority,
        match    => $match,
        action   => $action_sub,
    );
}

# Example DSL that shows the syntax.
sub examples {
    return <<'DSL';
rule classify_fix priority 20
    when ^(?:fix|bug|error|broken)
    then domain debug
    then mode debug
end

rule classify_build priority 20
    when ^(?:make|create|build|add|implement)
    then domain build
    then mode build
end

rule detect_no_strict priority 5
    when ^use strict;
    then tag perl_strict
end

rule detect_no_warnings priority 5
    when ^use warnings;
    then tag perl_warnings
end
DSL
}

1;
