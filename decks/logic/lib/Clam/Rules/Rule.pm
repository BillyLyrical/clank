# Clam::Rules::Rule — a single inference rule. Types: pattern, fuzzy, fact,
# inference, production.
#   pattern    regex → action (fast, free)
#   fuzzy      approximate string match → confidence 0..1 (Jaccard + substring)
#   fact       query against the shared SQLite fact store
#   inference  logical derivation over facts
#   production conditions over facts → action producing new fact(s) (chaining)
package Clam::Rules::Rule;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        name       => $args{name}       // 'unnamed',
        type       => $args{type}       // 'pattern',  # pattern|fuzzy|fact|inference|production
        priority   => $args{priority}   // 0,          # higher = checked first
        guard      => $args{guard},                    # optional: sub { ... } pre-check
        match      => $args{match},                    # pattern: regex, fuzzy: string, fact: hash
        conditions => $args{conditions} // [],         # production: array of condition hashes
        action     => $args{action},                   # sub { ... } to execute on match
        weight     => $args{weight}     // 1.0,        # fuzzy: confidence weight (0..1)
        enabled    => $args{enabled}    // 1,
    }, $class;
}

sub name     { return $_[0]->{name} }
sub type     { return $_[0]->{type} }
sub priority { return $_[0]->{priority} }
sub enabled  { return $_[0]->{enabled} }
sub match    { return $_[0]->{match} }
sub action   { return $_[0]->{action} }
sub weight   { return $_[0]->{weight} }

# Test if this rule matches. Returns confidence score (0..1) or 0.
sub test {
    my ($self, $context) = @_;
    return 0 unless $self->{enabled};

    if ($self->{guard}) {
        return 0 unless $self->{guard}->($context);
    }

    if ($self->{type} eq 'pattern') {
        my $text = $context->{text} // '';
        my $re   = $self->{match};
        return ($text =~ /$re/) ? $self->{weight} : 0;
    }
    elsif ($self->{type} eq 'fuzzy') {
        # Fuzzy string matching via word overlap.
        my $text   = $context->{text} // '';
        my $target = $self->{match} // '';
        return $self->_fuzzy_score($text, $target);
    }
    elsif ($self->{type} eq 'fact' || $self->{type} eq 'inference') {
        return $self->{weight};  # engine handles matching
    }
    return 0;
}

# Compute fuzzy match score (0..1). Uses word overlap + substring bonus.
sub _fuzzy_score {
    my ($self, $text, $target) = @_;
    return 0 unless $text && $target;

    # Exact match = 1.0
    return 1.0 if lc($text) eq lc($target);

    # Word overlap (Jaccard).
    my %wa    = map { lc($_) => 1 } split /\W+/, $text;
    my %wb    = map { lc($_) => 1 } split /\W+/, $target;
    my $inter = grep { $wb{$_} } keys %wa;
    my $union = scalar(keys %wa) + scalar(keys %wb) - $inter;
    my $jaccard = $union ? $inter / $union : 0;

    # Substring match bonus.
    my $substr_score = 0;
    $substr_score += 0.3 if index(lc($text), lc($target)) >= 0;
    $substr_score += 0.3 if index(lc($target), lc($text)) >= 0;

    my $score = ($jaccard * 0.7) + ($substr_score * 0.3);
    return $score * $self->{weight};
}

# Execute the rule's action. Returns result.
sub execute {
    my ($self, $context) = @_;
    return undef unless $self->{action};
    return $self->{action}->($context);
}

1;
