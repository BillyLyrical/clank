# CLAM-WIT: name=Query
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Execute SELECT queries — fetch rows, columns, single value
# CLAM-WIT: usage=Input: { conn_id: "sqlite:./data.db", sql: "SELECT * FROM users", fetch: "all" } Output: { rows: [...], count: N, columns: [...] }
# CLAM-WIT: hint=database query, select, sql, read
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Db::Query;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'db_query',
        description => 'Execute SELECT queries — fetch rows, columns, single value',
        parameters  => {
            type       => 'object',
            properties => {
                conn_id  => { type => 'string' },
                sql      => { type => 'string' },
                params   => { type => 'array'  },
                fetch    => { type => 'string', enum => ['all', 'single', 'column', 'arrayref'] },
                max_rows => { type => 'integer' },
            },
            required => ['conn_id', 'sql'],
        },
        execute => sub {
            my ($args) = @_;
            my $conn_id = $args->{conn_id} // '';
            my $sql     = $args->{sql}     // '';
            my $params  = $args->{params}  // [];
            my $fetch   = $args->{fetch}   // 'all';
            my $max_rows = $args->{max_rows} // 1000;

            return { error => "No SQL specified" } unless $sql;

            my $dbh = _get_dbh($conn_id);
            return { error => "No database connection" } unless $dbh;

            unless ($sql =~ /^\s*SELECT/i) {
                return { error => "Only SELECT queries allowed in db_query. Use db_execute for writes." };
            }

            my $sth = eval { $dbh->prepare($sql) };
            return { error => "Prepare failed: $@" } unless $sth;

            my $ok = eval { $sth->execute(@$params) };
            return { error => "Execute failed: $@" } unless $ok;

            my @columns = @{$sth->{NAME} || []};
            my @rows;
            my $count = 0;

            if ($fetch eq 'single') {
                my $row = $sth->fetchrow_hashref;
                @rows = $row ? ($row) : ();
            }
            elsif ($fetch eq 'column') {
                my $col = $sth->fetchcol_arrayref;
                @rows = $col ? @$col : ();
            }
            elsif ($fetch eq 'arrayref') {
                my $all = $sth->fetchall_arrayref({}, { MaxRows => $max_rows });
                @rows = $all ? @$all : ();
            }
            else {
                while (my $row = $sth->fetchrow_hashref) {
                    last if $count >= $max_rows;
                    push @rows, $row;
                    $count++;
                }
            }

            $sth->finish;

            return {
                topic   => 'db.query',
                rows    => \@rows,
                count   => scalar @rows,
                columns => \@columns,
                sql     => $sql,
            };
        },
    );
}

sub _get_dbh {
    my ($conn_id) = @_;
    # Access state from the global state store
    my $handles = $AI::Clam::State::db_handles // {};
    return $handles->{$conn_id} if $handles->{$conn_id};
    my @ids = keys %$handles;
    return $handles->{$ids[0]} if @ids;
    return undef;
}

1;
