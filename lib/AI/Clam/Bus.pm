# Pub/sub blackboard over AI::Clam::Store. The spine of clam.
package AI::Clam::Bus;
use strict;
use warnings;
use AI::Clam::Util qw(uuid4 now_ms jencode);

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        store      => $args{store} // die("AI::Clam::Bus requires store"),
        sender     => $args{sender} // 'bus',
        subs       => [],          # [ {pattern, code, name}, ... ]
        reply_waiters => {},       # correlation_id -> [coderefs] (request/reply)
    }, $class;
    return $self;
}

sub store  { $_[0]->{store} }
sub sender { $_[0]->{sender} }

# Glob-style topic match: 'tool.*' matches 'tool.call.bash'; '*' matches all.
# Public so journal queries (AI::Clam::Driver, clamd) can filter with the same
# semantics as subscriptions — SQLite LIKE does not understand '*'.
sub topic_matches {
    my ($pattern, $topic) = @_;
    return 1 if $pattern eq '*';
    my $re = quotemeta($pattern);
    $re =~ s{\\\*}{[^.]*}g;      # * -> within one segment
    $re =~ s{\\\.}{\\.}g;
    return $topic =~ /\A$re\z/;
}

# Glob-style topic match: 'tool.*' matches 'tool.call.bash'; '*' matches all.
sub _match {
    my ($pattern, $topic) = @_;
    return topic_matches($pattern, $topic);
}

# Subscribe to a topic pattern. Returns sub id for unsubscribe.
sub subscribe {
    my ($self, $pattern, $code, %o) = @_;
    my $id = uuid4();
    push @{$self->{subs}}, { id => $id, pattern => $pattern, code => $code, name => $o{name} };
    return $id;
}

sub unsubscribe {
    my ($self, $id) = @_;
    $self->{subs} = [ grep { $_->{id} ne $id } @{$self->{subs}} ];
}

# Publish an event: journal to SQLite first, then dispatch in-process.
# Returns the event id. Handler errors are captured (topic wit.error), never fatal.
sub publish {
    my ($self, $topic, $payload, %o) = @_;
    my $id = uuid4();
    my $correlation_id = $o{correlation_id} // $id;
    my $sender = $o{sender} // $self->{sender};

    $self->{store}->log_event(
        id => $id, correlation_id => $correlation_id,
        topic => $topic, sender => $sender, payload => $payload,
    );

    # dispatch to matching subscribers (registration order)
    my @results;
    for my $sub (@{$self->{subs}}) {
        next unless _match($sub->{pattern}, $topic);
        my $result = eval {
            $sub->{code}->({
                id => $id, correlation_id => $correlation_id,
                topic => $topic, sender => $sender, payload => $payload,
            });
        };
        if ($@) {
            my $err = $@;
            # journal the failure; do not recurse into dispatch of wit.error
            # (call store directly to avoid re-entry)
            $self->{store}->log_event(
                correlation_id => $correlation_id, topic => 'wit.error',
                sender => "sub:" . ($sub->{name} // 'anon'),
                payload => { error => "$err", for_topic => $topic },
            );
        } else {
            push @results, $result if defined $result;
        }
    }
    return { id => $id, correlation_id => $correlation_id, results => \@results };
}

# Request/reply: publish task topic, wait (poll journal) for result topic
# with same correlation_id. Returns payload or undef on timeout.
sub request {
    my ($self, $task_topic, $payload, %o) = @_;
    my $result_topic = $o{result_topic} // 'result.' . ($task_topic =~ s/^task\.//r);
    my $timeout_ms   = $o{timeout_ms} // 30_000;
    my $deadline     = now_ms() + $timeout_ms;

    my $pub = $self->publish($task_topic, $payload, sender => $o{sender});
    my $cid = $pub->{correlation_id};

    # poll the journal for a reply (agents may run in-process subscribers)
    while (now_ms() < $deadline) {
        my $rows = $self->{store}->query_events(
            correlation_id => $cid, topic => "$result_topic", limit => 1);
        if (@$rows) { return $rows->[0]{payload} }
        select undef, undef, undef, 0.05;   # 50ms sleep
    }
    return undef;
}

# Convenience: publish with sender tagged for a wit name.
sub publish_as {
    my ($self, $name, $topic, $payload, %o) = @_;
    return $self->publish($topic, $payload, sender => "wit:$name", %o);
}

1;
