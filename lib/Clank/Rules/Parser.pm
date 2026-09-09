# Clank::Rules::Parser — uses a Rules Engine as its backbone. Janet-style:
# patterns as rules, first/random match. Unifies parsing, classification, and
# transformation in one pluggable system.
package Clank::Rules::Parser;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        engine => $args{engine},  # Clank::Rules::Engine
    }, $class;
}

# Parse input through rule engine. Returns { rule, result } or undef.
sub parse {
    my ($self, $input, %opts) = @_;
    my $strategy = $opts{strategy} // 'first';

    my $context = {
        text     => $input,
        pos      => 0,
        captures => [],
    };

    if ($strategy eq 'first') {
        my $rule   = $self->{engine}->find($context);
        return undef unless $rule;
        my $result = $rule->execute($context);
        return { rule => $rule->name, result => $result };
    }
    elsif ($strategy eq 'random') {
        my @matches = $self->{engine}->find_all($context);
        return undef unless @matches;
        my $pick   = $matches[rand @matches];
        my $result = $pick->execute($context);
        return { rule => $pick->name, result => $result };
    }
    elsif ($strategy eq 'all') {
        my $results = $self->{engine}->execute({ %$context, _strategy => 'all' });
        return { results => $results };
    }

    return undef;
}

# Convenience: classify text through pattern rules. Returns domain or 'general'.
sub classify {
    my ($self, $text) = @_;
    my $result = $self->parse($text);
    return $result ? $result->{result}{domain} // 'general' : 'general';
}

# Convenience: extract structured data from text.
sub extract {
    my ($self, $text) = @_;
    my $result = $self->parse($text);
    return $result ? $result->{result} : {};
}

# Convenience: transform text through rules (uses the rule's output action).
sub transform {
    my ($self, $text) = @_;
    my $result = $self->parse($text);
    return $text unless $result && $result->{result}{output};
    return $result->{result}{output};
}

# Chain: parse → transform → parse → ... until no more rules match.
sub chain {
    my ($self, $input, %opts) = @_;
    my $max     = $opts{max} // 10;
    my $current = $input;
    my @steps;

    for my $i (1 .. $max) {
        my $result = $self->parse($current);
        last unless $result;
        push @steps, { rule => $result->{rule}, output => $result->{result}{output} // $current };
        $current = $result->{result}{output} // $current;
    }

    return { final => $current, steps => \@steps };
}

1;
