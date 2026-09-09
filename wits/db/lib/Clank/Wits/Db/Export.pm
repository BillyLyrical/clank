# CLANK-WIT: name=Export
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Export data — dump tables to CSV, JSON, SQL, or Markdown
# CLANK-WIT: usage=Input: { action: "table", table: "users", format: "csv", file: "users.csv" } Output: { ok: true, file: "users.csv", rows: N }
# CLANK-WIT: hint=database export, dump, csv, json, sql, markdown
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Db::Export;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'dbshell_export',
        description => 'Export data — dump tables to CSV, JSON, SQL, or Markdown',
        parameters  => {
            type       => 'object',
            properties => {
                action => { type => 'string', enum => ['table', 'query', 'dump'] },
                table  => { type => 'string' },
                sql    => { type => 'string' },
                format => { type => 'string', enum => ['csv', 'json', 'sql', 'markdown'] },
                file   => { type => 'string' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'table';
            my $format = $args->{format} // 'csv';
            my $file   = $args->{file}   // '';

            # Note: This tool requires access to session state (dbshell dbh).
            # The actual implementation depends on the Clank runtime environment.

            if ($action eq 'table') {
                my $table = $args->{table} // '';
                return { ok => 0, error => "No table specified" } unless $table;
                return { ok => 0, error => "No database connected" };
            }

            if ($action eq 'query') {
                my $sql = $args->{sql} // '';
                return { ok => 0, error => "No SQL" } unless $sql;
                return { ok => 0, error => "No database connected" };
            }

            if ($action eq 'dump') {
                return { ok => 0, error => "No database connected" };
            }

            return { ok => 0, error => "Unknown action: $action" };
        },
    );
}

sub _export {
    my ($rows, $columns, $format, $name) = @_;

    if ($format eq 'json') {
        eval { require JSON::PP; return JSON::PP::encode_json($rows) };
        return '[]';
    }

    if ($format eq 'csv') {
        my $csv = join(',', @$columns) . "\n";
        for my $row (@$rows) {
            $csv .= join(',', map { defined $_ ? "\"$_\"" : 'NULL' } @$row{@$columns}) . "\n";
        }
        return $csv;
    }

    if ($format eq 'sql') {
        my $sql = "-- Export of $name\n\n";
        for my $row (@$rows) {
            my @vals = map { defined $_ ? "'$_'" : 'NULL' } @$row{@$columns};
            $sql .= "INSERT INTO $name (" . join(',', @$columns) . ") VALUES (" . join(',', @vals) . ");\n";
        }
        return $sql;
    }

    if ($format eq 'markdown') {
        my $md = "| " . join(' | ', @$columns) . " |\n";
        $md .= "| " . join(' | ', map { '---' } @$columns) . " |\n";
        for my $row (@$rows) {
            $md .= "| " . join(' | ', map { defined $_ ? "$_" : 'NULL' } @$row{@$columns}) . " |\n";
        }
        return $md;
    }

    return '';
}

1;
