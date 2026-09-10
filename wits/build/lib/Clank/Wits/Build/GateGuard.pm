# CLANK-WIT: name=GateGuard
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Fact-forcing pre-action gate — blocks edits until investigation
# CLANK-WIT: usage=Bus hook on tool_call. Blocks first edit/write per file, destructive bash every time, routine bash once per session. Returns { block, reason }.
# CLANK-WIT: hint=gateguard, force investigation, pre-edit gate, edit block, destructive bash, fact forcing, quality gate
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::GateGuard;
use strict;
use warnings;

my @EDIT_TOOLS  = qw( edit write );
my @DESTRUCTIVE = qw(
    rm\ -rf  rm\ -fr
    git\ reset\ --hard
    git\ push\ --force  git\ push\ -f
    git\ checkout\ --  git\ checkout\ -f
    drop\ table  drop\ database
    truncate
    dd\ if=
    mkfs
    format
);

sub register {
    my ($self, $api) = @_;

    my $state = {
        investigated   => {},
        bash_seen      => {},
        deny_count     => 0,
        max_full_denials => 3,
        exempt_globs   => [],
    };

    $api->on('pre_tool_use', sub {
        my ($ev) = @_;
        my $name = $ev->{payload}{name} // '';
        my $input = $ev->{payload}{input} // {};

        if (grep { $_ eq $name } @EDIT_TOOLS) {
            return _gate_edit($state, $input);
        }
        elsif ($name eq 'bash' || $name eq 'systemq' || $name eq 'backtick') {
            return _gate_bash($state, $input);
        }

        return;
    });

    $api->register_command('gateguard',
        description => 'gateguard: status | reset | exempt <glob>',
        handler => sub {
            my ($ctx, $args) = @_;
            my ($subcmd, @rest) = split /\s+/, ($args // '');
            $subcmd //= 'status';

            if ($subcmd eq 'status') {
                my $investigated = scalar keys %{ $state->{investigated} };
                my $bash_seen    = scalar keys %{ $state->{bash_seen} };
                return "GateGuard status:\n"
                     . "  files investigated: $investigated\n"
                     . "  bash commands seen: $bash_seen\n"
                     . "  deny count: $state->{deny_count}\n"
                     . "  exempt globs: " . join(', ', @{ $state->{exempt_globs} }) . "\n";
            }
            elsif ($subcmd eq 'reset') {
                $state->{investigated} = {};
                $state->{bash_seen}    = {};
                $state->{deny_count}   = 0;
                return "GateGuard state reset.\n";
            }
            elsif ($subcmd eq 'exempt') {
                my $glob = join(' ', @rest);
                return "Usage: /gateguard exempt <glob>\n" unless $glob;
                push @{ $state->{exempt_globs} }, $glob;
                return "Added exempt glob: $glob\n";
            }

            return "Usage: /gateguard status|reset|exempt <glob>\n";
        },
    );
}

sub _gate_edit {
    my ($state, $input) = @_;

    my $file = $input->{file_path} // $input->{path} // $input->{file} // '';
    return unless $file;

    for my $glob (@{ $state->{exempt_globs} }) {
        return if _matches_glob($file, $glob);
    }

    return if $state->{investigated}{$file};

    $state->{investigated}{$file} = 1;
    $state->{deny_count}++;

    my $full = $state->{deny_count} <= $state->{max_full_denials};

    if ($full) {
        return {
            block  => 1,
            reason => "GateGuard: Before editing $file, present these facts:\n"
                    . "1. List ALL files that import/require this file (grep the tree)\n"
                    . "2. List the public functions/subs affected by this change\n"
                    . "3. If this file reads/writes data, show field names and structure\n"
                    . "4. Quote the user's current instruction verbatim\n"
                    . "\nThen retry the edit.",
        };
    }
    else {
        return {
            block  => 1,
            reason => "GateGuard #$state->{deny_count}: investigate before editing $file (see earlier demands)",
        };
    }
}

sub _gate_bash {
    my ($state, $input) = @_;

    my $cmd = $input->{command} // $input->{cmd} // '';
    return unless $cmd;

    for my $pattern (@DESTRUCTIVE) {
        if ($cmd =~ /\Q$pattern\E/) {
            return {
                block  => 1,
                reason => "GateGuard: Destructive command detected: $pattern\n"
                        . "1. List all files/data this command will modify or delete\n"
                        . "2. Write a one-line rollback procedure\n"
                        . "3. Quote the user's current instruction verbatim",
            };
        }
    }

    my $key = $cmd;
    $key =~ s/\s+/ /g;
    $key =~ s/^\s+|\s+$//g;

    unless ($state->{bash_seen}{$key}) {
        $state->{bash_seen}{$key} = 1;
        return {
            block  => 1,
            reason => "GateGuard: Before running: $cmd\n"
                    . "1. State the current user request in one sentence\n"
                    . "2. State what this specific command verifies or produces",
        };
    }

    return;
}

sub _matches_glob {
    my ($path, $glob) = @_;
    my $re = quotemeta($glob);
    $re =~ s/\\\*/.*/g;
    $re =~ s/\\\?/./g;
    return $path =~ /$re/;
}

1;
