# CLAM-WIT: name=Execute
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Execute INSERT, UPDATE, DELETE — with transaction support
# CLAM-WIT: usage=Input: { conn_id: "sqlite:./data.db", sql: "INSERT INTO users (name) VALUES (?)", params: ["Alice"] } Output: { ok: true, rows_affected: 1, last_insert_id: 5 }
# CLAM-WIT: hint=database execute, insert, update, delete, write, transaction
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Db::Execute;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'db_execute',
        description => 'Execute INSERT, UPDATE, DELETE — with transaction support',
        parameters  => {
            type       => 'object',
            properties => {
                conn_id     => { type => 'string' },
                sql         => { type => 'string' },
                params      => { type => 'array'  },
                transaction => { type => 'array'  },
            },
            required => ['conn_id'],
        },
        execute => sub {
            my ($args) = @_;
            my $conn_id     = $args->{conn_id}     // '';
            my $sql         = $args->{sql}         // '';
            my $params      = $args->{params}      // [];
            my $transaction = $args->{transaction} // [];

            if (@$transaction) {
                return _run_transaction($conn_id, $transaction);
            }

            return { error => "No SQL specified" } unless $sql;

            my $dbh = _get_dbh($conn_id);
            return { error => "No database connection" } unless $dbh;

            if ($sql =~ /^\s*SELECT/i) {
                return { error => "SELECT not allowed in db_execute. Use db_query for reads." };
            }

            my $sth = eval { $dbh->prepare($sql) };
            return { error => "Prepare failed: $@" } unless $sth;

            my $ok = eval { $sth->execute(@$params) };
            return { error => "Execute failed: $@" } unless $ok;

            my $rows_affected = $sth->rows;
            my $last_insert_id = eval { $dbh->last_insert_id(undef, undef, undef, undef) } || 0;

            $sth->finish;

            return {
                topic          => 'db.executed',
                ok             => 1,
                rows_affected  => $rows_affected,
                last_insert_id => $last_insert_id,
                sql            => $sql,
            };
        },
    );
}

sub _run_transaction {
    my ($conn_id, $stmts) = @_;
    my $dbh = _get_dbh($conn_id);
    return { error => "No database connection" } unless $dbh;

    $dbh->begin_work;
    my @results;
    my $total_affected = 0;

    for my $stmt (@$stmts) {
        my $sth = eval { $dbh->prepare($stmt->{sql}) };
        unless ($sth) {
            $dbh->rollback;
            return { error => "Prepare failed in transaction: $@" };
        }

        my $ok = eval { $sth->execute(@{$stmt->{params} // []}) };
        unless ($ok) {
            $dbh->rollback;
            return { error => "Execute failed in transaction: $@" };
        }

        $total_affected += $sth->rows;
        push @results, { sql => $stmt->{sql}, rows_affected => $sth->rows };
        $sth->finish;
    }

    $dbh->commit;

    return {
        topic          => 'db.transaction',
        ok             => 1,
        statements     => scalar @results,
        total_affected => $total_affected,
        results        => \@results,
    };
}

sub _get_dbh {
    my ($conn_id) = @_;
    my $handles = $Clam::State::db_handles // {};
    return $handles->{$conn_id} if $handles->{$conn_id};
    my @ids = keys %$handles;
    return $handles->{$ids[0]} if @ids;
    return undef;
}

1;
