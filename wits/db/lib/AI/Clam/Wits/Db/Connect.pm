# CLAM-WIT: name=Connect
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Connect to databases — SQLite, MySQL, PostgreSQL
# CLAM-WIT: usage=Input: { driver: "sqlite", database: "./data.db" } Output: { ok: true, driver: "sqlite", dbh: <dbh> }
# CLAM-WIT: hint=database connect, dbi, sqlite, postgresql, mysql
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Db::Connect;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'db_connect',
        description => 'Connect to databases — SQLite, MySQL, PostgreSQL',
        parameters  => {
            type       => 'object',
            properties => {
                driver   => { type => 'string', enum => ['sqlite', 'mysql', 'pgsql', 'postgresql'] },
                database => { type => 'string' },
                host     => { type => 'string' },
                port     => { type => 'integer' },
                user     => { type => 'string' },
                password => { type => 'string' },
            },
            required => ['driver', 'database'],
        },
        execute => sub {
            my ($args) = @_;
            my $driver   = $args->{driver}   // 'sqlite';
            my $database = $args->{database} // '';
            my $host     = $args->{host}     // 'localhost';
            my $port     = $args->{port}     // '';
            my $user     = $args->{user}     // '';
            my $password = $args->{password} // '';

            eval { require DBI; 1 } or return { error => "DBI not installed" };

            my $dsn;
            my @args;

            if ($driver eq 'sqlite') {
                return { error => "No database file specified" } unless $database;
                $dsn = "dbi:SQLite:dbname=$database";
                @args = ($dsn, '', '', { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
            }
            elsif ($driver eq 'mysql') {
                eval { require DBD::mysql; 1 } or return { error => "DBD::mysql not installed" };
                $port //= 3306;
                $dsn = "dbi:mysql:database=$database;host=$host;port=$port";
                @args = ($dsn, $user, $password, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
            }
            elsif ($driver eq 'pgsql' || $driver eq 'postgresql') {
                eval { require DBD::Pg; 1 } or return { error => "DBD::Pg not installed" };
                $driver = 'pgsql';
                $port //= 5432;
                $dsn = "dbi:Pg:dbname=$database;host=$host;port=$port";
                @args = ($dsn, $user, $password, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
            }
            else {
                return { error => "Unknown driver: $driver" };
            }

            my $dbh = eval { DBI->connect(@args) };
            return { error => "Connection failed: $@" } unless $dbh;

            if ($driver eq 'sqlite') {
                $dbh->do("PRAGMA journal_mode=WAL");
                $dbh->do("PRAGMA foreign_keys=ON");
                $dbh->do("PRAGMA busy_timeout=5000");
                $dbh->do("PRAGMA synchronous=NORMAL");
            }

            return {
                topic    => 'db.connected',
                ok       => 1,
                driver   => $driver,
                database => $database,
                host     => $host,
                conn_id  => "$driver:$database",
                ping     => $dbh->ping,
            };
        },
    );
}

1;
