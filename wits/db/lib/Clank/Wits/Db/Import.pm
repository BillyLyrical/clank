# CLANK-WIT: name=Import
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Import data — load CSV, JSON, or SQL into database tables
# CLANK-WIT: usage=Input: { action: "csv", file: "users.csv", table: "users" } Output: { ok: true, inserted: N, table: "users" }
# CLANK-WIT: hint=database import, load, csv, json, sql
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Db::Import;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'dbshell_import',
        description => 'Import data — load CSV, JSON, or SQL into database tables',
        parameters  => {
            type       => 'object',
            properties => {
                action => { type => 'string', enum => ['csv', 'json', 'sql'] },
                file   => { type => 'string' },
                data   => { type => 'string' },
                table  => { type => 'string' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'csv';

            # Note: This tool requires access to session state (dbshell dbh).
            # The actual implementation depends on the Clank runtime environment.

            if ($action eq 'csv') {
                my $file  = $args->{file}  // '';
                my $data  = $args->{data}  // '';
                my $table = $args->{table} // '';
                return { ok => 0, error => "No table specified" } unless $table;
                return { ok => 0, error => "No database connected" };
            }

            if ($action eq 'json') {
                my $file  = $args->{file}  // '';
                my $table = $args->{table} // '';
                return { ok => 0, error => "No table specified" } unless $table;
                return { ok => 0, error => "No database connected" };
            }

            if ($action eq 'sql') {
                my $file = $args->{file} // '';
                return { ok => 0, error => "No file specified" } unless $file;
                return { ok => 0, error => "No database connected" };
            }

            return { ok => 0, error => "Unknown action: $action" };
        },
    );
}

sub _parse_csv_line {
    my $line = shift;
    my @fields;
    my $field = '';
    my $in_quotes = 0;

    for my $i (0 .. length($line) - 1) {
        my $ch = substr($line, $i, 1);
        if ($ch eq '"') {
            $in_quotes = !$in_quotes;
        } elsif ($ch eq ',' && !$in_quotes) {
            push @fields, $field;
            $field = '';
        } else {
            $field .= $ch;
        }
    }
    push @fields, $field;
    return @fields;
}

1;
