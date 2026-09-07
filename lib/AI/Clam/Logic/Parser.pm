# Recursive-descent Datalog parser (no Marpa dependency).
#   parent(alice,bob).
#   gp(X,Y) :- parent(X,Z), parent(Z,Y).
package AI::Clam::Logic::Parser;
use strict;
use warnings;
use AI::Clam::Logic::KnowledgeBase ();

sub parse {
    my ($class, $text) = @_;
    my $kb   = AI::Clam::Logic::KnowledgeBase->new;
    my $toks = _tokenize($text);
    my $i    = 0;

    while ($toks->[$i][0] ne 'eof') {
        # head: pred(args)
        die "parse error: expected predicate, got '" . $toks->[$i][1] . "'\n"
            unless $toks->[$i][0] eq 'atom';
        my $pred = $toks->[$i++][1];
        die "parse error: expected ( after $pred\n" unless $toks->[$i][0] eq '(';
        $i++;
        my @args = _parse_args($toks, \$i);
        die "parse error: expected )\n" unless $toks->[$i][0] eq ')';
        $i++;

        if ($toks->[$i][0] eq ':-') {
            $i++;
            my @body = (_parse_goal($toks, \$i));
            while ($toks->[$i][0] eq ',') {
                $i++;
                push @body, _parse_goal($toks, \$i);
            }
            die "parse error: expected . after rule body\n" unless $toks->[$i][0] eq '.';
            $i++;
            $kb->add_rule({ head => [ $pred, @args ], body => \@body });
        } else {
            die "parse error: expected . after fact\n" unless $toks->[$i][0] eq '.';
            $i++;
            $kb->add_fact([ $pred, @args ]);
        }
    }
    return $kb;
}

sub _parse_goal {
    my ($toks, $iref) = @_;
    die "parse error: expected predicate in goal\n" unless $toks->[$$iref][0] eq 'atom';
    my $pred = $toks->[$$iref++][1];
    die "parse error: expected ( in goal\n" unless $toks->[$$iref][0] eq '(';
    $$iref++;
    my @args = _parse_args($toks, $iref);
    die "parse error: expected ) in goal\n" unless $toks->[$$iref][0] eq ')';
    $$iref++;
    return [ $pred, @args ];
}

sub _parse_args {
    my ($toks, $iref) = @_;
    my @args;
    return @args if $toks->[$$iref][0] eq ')';      # nullary: pred()
    push @args, _parse_term($toks, $iref);
    while ($toks->[$$iref][0] eq ',') {
        $$iref++;
        push @args, _parse_term($toks, $iref);
    }
    return @args;
}

sub _parse_term {
    my ($toks, $iref) = @_;
    my $tk = $toks->[$$iref][0];
    if ($tk eq 'atom' || $tk eq 'var' || $tk eq 'num') {
        my $v = $toks->[$$iref][1];
        $$iref++;
        return $v;
    }
    if ($tk eq '[') {
        $$iref++;
        my @items;
        unless ($toks->[$$iref][0] eq ']') {
            push @items, _parse_term($toks, $iref);
            while ($toks->[$$iref][0] eq ',') {
                $$iref++;
                push @items, _parse_term($toks, $iref);
            }
        }
        die "parse error: expected ]\n" unless $toks->[$$iref][0] eq ']';
        $$iref++;
        return \@items;
    }
    die "parse error: unexpected token '" . ($toks->[$$iref][1] // $tk) . "'\n";
}

# --- tokenizer -------------------------------------------------------------
sub _tokenize {
    my ($text) = @_;
    $text =~ s/%[^\n]*//g;                       # % comments to end of line
    pos($text) = 0;
    my @toks;
    while (pos($text) < length($text)) {
        if     ($text =~ /\G\s+/gc)                          { next }
        elsif  ($text =~ /\G'((?:[^']|'')*)'/gc)             { my $q = $1; $q =~ s/''/'/g; push @toks, ['atom', $q] }
        elsif  ($text =~ /\G(:-)/gc)                         { push @toks, [':-', ':-'] }
        elsif  ($text =~ /\G([\(\)\[\],\.])/gc)              { push @toks, [$1, $1] }
        elsif  ($text =~ /\G(-?\d+(?:\.\d+)?)/gc)            { push @toks, ['num', $1 + 0] }
        elsif  ($text =~ /\G([A-Z_][a-zA-Z0-9_]*)/gc)        { push @toks, ['var', $1] }
        elsif  ($text =~ /\G([a-z][a-zA-Z0-9_]*)/gc)         { push @toks, ['atom', $1] }
        else {
            die "parse error: unexpected character at position " . pos($text)
              . ": '" . substr($text, pos($text), 20) . "'\n";
        }
    }
    push @toks, ['eof', ''];
    return \@toks;
}

1;
