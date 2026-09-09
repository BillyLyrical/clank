# Clank::Band — composable societies of wits. A "Band" (from Minsky's
# Society of Mind) is a named workflow: a trigger topic, a sequence of
# steps, and an output topic. Each step invokes a registered wit or
# inline code. The band subscribes to the trigger on the bus, runs
# the steps in order, and publishes the result.
#
# Bands are defined as TOML files in bands/ (project) or ~/.clank/bands/ (user).
# The bus is the only integration point — bands never call wits directly.
package Clank::Band;
use strict;
use warnings;
use Clank::Util qw(jencode jdecode);

sub new {
    my ($class, %args) = @_;
    return bless {
        bus        => $args{bus},
        store      => $args{store},
        metrics    => $args{metrics},
        tracer     => $args{tracer},
        dispatch   => $args{dispatch},    # Wit::Dispatch for inter-wit calls
        bands      => {},                  # name => { definition }
    }, $class;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;
    $self->{bus} //= $api->bus;
    $self->{store} //= $api->store;

    # Lazily create dispatch from loaded wits.
    unless ($self->{dispatch}) {
        eval {
            require Clank::Wit::Dispatch;
            $self->{dispatch} = Clank::Wit::Dispatch->new(wits => {});
        };
    }

    # Subscribe to band.discover for dynamic band registration.
    $api->on('band.discover', sub { $self->_on_discover(@_) });

    return $self;
}

# === DISCOVERY ===

sub discover {
    my (%o) = @_;
    my @roots = ('bands');
    push @roots, "$ENV{HOME}/.clank/bands" if defined $ENV{HOME};
    push @roots, @{ $o{extra} // [] };
    my (@bands, %seen);
    _scan($_, \@bands, \%seen) for grep { -d } @roots;
    return @bands;
}

sub _scan {
    my ($dir, $out, $seen) = @_;
    opendir(my $dh, $dir) or return;
    for my $e (sort readdir $dh) {
        next if $e =~ /^\./;
        my $p = "$dir/$e";
        if (-d $p) {
            my $toml = "$p/band.toml";
            if (-f $toml) {
                my $def = parse_band($toml);
                if ($def && defined $def->{name} && !$seen->{ $def->{name} }++) {
                    $def->{file_path} = $toml;
                    $def->{band_dir} = $p;
                    push @$out, $def;
                }
            }
            # Also scan subdirectories.
            _scan($p, $out, $seen);
        }
    }
    closedir $dh;
}

# === TOML PARSING ===

sub parse_band {
    my ($file) = @_;
    open my $fh, '<', $file or return undef;
    local $/; my $content = <$fh>; close $fh;
    return undef unless defined $content && length $content;

    require TOML::Tiny;
    my $data = eval { TOML::Tiny::from_toml($content) };
    return undef if $@ || ref $data ne 'HASH';

    # Validate required fields.
    return undef unless defined $data->{name};
    $data->{trigger} //= "band.$data->{name}";
    $data->{steps} //= [];
    $data->{description} //= '';

    return $data;
}

# === REGISTRATION ===

# Register a band: subscribe to its trigger topic and wire the step chain.
sub register_band {
    my ($self, $band) = @_;
    my $name = $band->{name} or return;
    my $trigger = $band->{trigger} or return;
    my $steps = $band->{steps} // [];
    return unless @$steps;

    $self->{bands}{$name} = $band;

    my $bus = $self->{bus};
    my $dispatch = $self->{dispatch};
    my $metrics = $self->{metrics};
    my $tracer = $self->{tracer};

    # Subscribe to the trigger topic.
    $bus->subscribe($trigger, sub {
        my ($ev) = @_;
        my $payload = $ev->{payload} // {};
        my $cid = $ev->{correlation_id};

        my $band_span;
        $band_span = $tracer->start_span("band.$name", topic => 'band')
            if $tracer;

        my $state = { %$payload, _band => $name, _step_results => [] };
        my $ok = 1;

        for my $step (@$steps) {
            my $step_name = $step->{name} // 'unnamed';
            my $handler = $step->{handler};
            my $code = $step->{code};
            my $step_topic = $step->{topic};

            my $step_span;
            $step_span = $tracer->start_span("band.$name.step.$step_name", topic => 'band')
                if $tracer;

            my $result;
            eval {
                if ($handler && $dispatch) {
                    # Invoke a registered wit by name.
                    $result = $dispatch->execute($handler, $state);
                } elsif ($code) {
                    # Execute inline Perl code.
                    my $sub = eval "sub { $code }";
                    if ($sub) {
                        $result = $sub->($state, $dispatch);
                    } else {
                        warn "[band:$name] step '$step_name' code eval error: $@";
                        $ok = 0;
                    }
                }
            };
            if ($@) {
                warn "[band:$name] step '$step_name' error: $@";
                $ok = 0;
            }

            if ($metrics) {
                $metrics->inc("band.$name.step.$step_name");
                $metrics->inc("band.$name.steps") if $ok;
            }

            if ($tracer) {
                $tracer->end_span($step_span, {
                    step => $step_name, ok => $ok,
                }) if $step_span;
            }

            last unless $ok;

            # Merge step result into state.
            if (ref $result eq 'HASH') {
                $state = { %$state, %$result };
            } elsif (defined $result) {
                $state->{result} = $result;
            }

            push @{$state->{_step_results}}, {
                step => $step_name,
                ok   => $ok,
            };
        }

        # Publish to the band's output topic.
        my $output_topic = $band->{output} // "$trigger.done";
        $bus->publish($output_topic, {
            band    => $name,
            ok      => $ok,
            state   => $state,
            results => $state->{_step_results},
        }, correlation_id => $cid, sender => "band:$name");

        if ($tracer) {
            $tracer->end_span($band_span, {
                band => $name, ok => $ok,
                steps => scalar @{ $state->{_step_results} },
            }) if $band_span;
        }

        $metrics->inc("band.$name.runs") if $metrics;

        return { ok => $ok, band => $name };
    }, name => "band:$name");

    return 1;
}

# === BUS HANDLERS ===

sub _on_discover {
    my ($self, $ev) = @_;
    my @bands = discover();
    for my $band (@bands) {
        $self->register_band($band) unless $self->{bands}{ $band->{name} };
    }
    return { bands => [ map { $_->{name} } @bands ] };
}

# === LISTING ===

sub list_bands {
    my ($self) = @_;
    return [ sort keys %{$self->{bands}} ];
}

sub get_band {
    my ($self, $name) = @_;
    return $self->{bands}{$name};
}

1;
