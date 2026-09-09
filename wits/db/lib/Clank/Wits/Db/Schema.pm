# CLANK-WIT: name=Schema
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Inspect database schema — tables, columns, indexes, constraints
# CLANK-WIT: usage=Input: { conn_id: "sqlite:./data.db", action: "tables" } Output: { tables: ["users", "posts"], count: 2 }
# CLANK-WIT: hint=database schema, introspect, tables, columns, indexes
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Db::Schema;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'db_schema',
        description => 'Inspect database schema — tables, columns, indexes, constraints',
        parameters  => {
            type       => 'object',
            properties => {
                conn_id => { type => 'string' },
                action  => { type => 'string', enum => ['tables', 'columns', 'indexes', 'info'] },
                table   => { type => 'string' },
            },
            required => ['conn_id', 'action'],
        },
        execute => sub {
            my ($args) = @_;
            my $conn_id = $args->{conn_id} // '';
            my $action  = $args->{action}  // 'tables';
            my $table   = $args->{table}   // '';

            my $dbh = _get_dbh($conn_id);
            return { error => "No database connection" } unless $dbh;

            my $driver = $dbh->{Driver}{Name} // 'sqlite';

            if ($action eq 'tables') {
                my @tables;
                if ($driver eq 'SQLite') {
                    my $sth = $dbh->prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_arrayref) {
                        push @tables, $row->[0];
                    }
                    $sth->finish;
                }
                elsif ($driver eq 'mysql') {
                    my $sth = $dbh->prepare("SHOW TABLES");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_arrayref) {
                        push @tables, $row->[0];
                    }
                    $sth->finish;
                }
                elsif ($driver eq 'Pg') {
                    my $sth = $dbh->prepare("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_arrayref) {
                        push @tables, $row->[0];
                    }
                    $sth->finish;
                }

                return {
                    topic  => 'schema.tables',
                    tables => \@tables,
                    count  => scalar @tables,
                    driver => $driver,
                };
            }

            if ($action eq 'columns') {
                return { error => "No table specified" } unless $table;

                my @columns;
                if ($driver eq 'SQLite') {
                    my $sth = $dbh->prepare("PRAGMA table_info($table)");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_hashref) {
                        push @columns, {
                            name    => $row->{name},
                            type    => $row->{type},
                            notnull => $row->{notnull},
                            pk      => $row->{pk},
                            default => $row->{dflt_value},
                        };
                    }
                    $sth->finish;
                }
                elsif ($driver eq 'mysql') {
                    my $sth = $dbh->prepare("DESCRIBE $table");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_hashref) {
                        push @columns, {
                            name    => $row->{Field},
                            type    => $row->{Type},
                            notnull => $row->{Null} eq 'NO' ? 1 : 0,
                            pk      => $row->{Key} eq 'PRI' ? 1 : 0,
                            default => $row->{Default},
                        };
                    }
                    $sth->finish;
                }
                elsif ($driver eq 'Pg') {
                    my $sth = $dbh->prepare("
                        SELECT column_name, data_type, is_nullable, column_default
                        FROM information_schema.columns
                        WHERE table_name = ? AND table_schema = 'public'
                        ORDER BY ordinal_position
                    ");
                    $sth->execute($table);
                    while (my $row = $sth->fetchrow_hashref) {
                        push @columns, {
                            name    => $row->{column_name},
                            type    => $row->{data_type},
                            notnull => $row->{is_nullable} eq 'NO' ? 1 : 0,
                            default => $row->{column_default},
                        };
                    }
                    $sth->finish;
                }

                return {
                    topic   => 'schema.columns',
                    table   => $table,
                    columns => \@columns,
                    count   => scalar @columns,
                };
            }

            if ($action eq 'indexes') {
                return { error => "No table specified" } unless $table;

                my @indexes;
                if ($driver eq 'SQLite') {
                    my $sth = $dbh->prepare("PRAGMA index_list($table)");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_hashref) {
                        push @indexes, {
                            name   => $row->{name},
                            unique => $row->{unique},
                        };
                    }
                    $sth->finish;
                }
                elsif ($driver eq 'mysql') {
                    my $sth = $dbh->prepare("SHOW INDEX FROM $table");
                    $sth->execute;
                    while (my $row = $sth->fetchrow_hashref) {
                        push @indexes, {
                            name   => $row->{Key_name},
                            column => $row->{Column_name},
                            unique => !$row->{Non_unique},
                        };
                    }
                    $sth->finish;
                }

                return {
                    topic   => 'schema.indexes',
                    table   => $table,
                    indexes => \@indexes,
                    count   => scalar @indexes,
                };
            }

            if ($action eq 'info') {
                my $driver_info = {
                    name    => $driver,
                    version => $dbh->{pg_server_version} // $dbh->get_info(18) // 'unknown',
                };
                return {
                    topic  => 'schema.info',
                    driver => $driver_info,
                };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _get_dbh {
    my ($conn_id) = @_;
    my $handles = $Clank::State::db_handles // {};
    return $handles->{$conn_id} if $handles->{$conn_id};
    my @ids = keys %$handles;
    return $handles->{$ids[0]} if @ids;
    return undef;
}

1;
