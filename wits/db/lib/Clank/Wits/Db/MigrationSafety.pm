# CLANK-WIT: name=MigrationSafety
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Audit migration files for safety and generate expand-contract plans
# CLANK-WIT: usage=Input: { file?: string, sql?: string } or { table: string, old_column: string, new_column: string }
# CLANK-WIT: hint=database migration, schema change, rollback, zero-downtime, expand-contract, concurrent index, backfill, safe migration
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Db::MigrationSafety;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'migration_safety',
        description => 'Audit a migration file or SQL for safety issues',
        parameters  => {
            type       => 'object',
            properties => {
                file => { type => 'string', description => 'Path to migration file' },
                sql  => { type => 'string', description => 'Raw SQL to audit' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $file = $args->{file};
            my $sql  = $args->{sql};

            if (!$file && !$sql) {
                return { error => "Provide either 'file' or 'sql'" };
            }

            my $content;
            if ($file) {
                open my $fh, '<', $file or return { error => "Cannot read $file: $!" };
                local $/;
                $content = <$fh>;
                close $fh;
            }
            else {
                $content = $sql;
            }

            my @issues;
            my @lines = split /\n/, $content;

            for my $i (0 .. $#lines) {
                my $line_no = $i + 1;
                my $line    = $lines[$i];

                if ($line =~ /ALTER\s+TABLE\s+\S+\s+ALTER\s+COLUMN\s+\S+\s+SET\s+NOT\s+NULL/i) {
                    my $has_default = 0;
                    for my $j ($i + 1 .. $#lines) {
                        last if $lines[$j] =~ /;/;
                        $has_default = 1 if $lines[$j] =~ /DEFAULT/i;
                    }
                    push @issues, {
                        severity => 'error',
                        message  => 'NOT NULL without DEFAULT on existing column — blocks inserts',
                        line     => $line_no,
                    } if !$has_default;
                }

                if ($line =~ /CREATE\s+INDEX(?!\s+CONCURRENTLY)/i) {
                    push @issues, {
                        severity => 'warning',
                        message  => 'CREATE INDEX without CONCURRENTLY — will lock table on large datasets',
                        line     => $line_no,
                    };
                }

                if ($line =~ /DROP\s+COLUMN/i && $content !~ /--.*remove.*code/i) {
                    push @issues, {
                        severity => 'warning',
                        message  => 'DROP COLUMN before code removal — may break running applications',
                        line     => $line_no,
                    };
                }

                if ($line =~ /BEGIN|COMMIT|START\s+TRANSACTION/i) {
                    my $has_ddl = grep { /CREATE|ALTER|DROP|TRUNCATE/i } @lines;
                    my $has_dml = grep { /INSERT|UPDATE|DELETE|MERGE/i } @lines;
                    if ($has_ddl && $has_dml) {
                        push @issues, {
                            severity => 'warning',
                            message  => 'Mixed DDL and DML in same transaction — consider separating',
                            line     => $line_no,
                        };
                        last;
                    }
                }

                if ($line =~ /ALTER\s+TABLE\s+\S+\s+ADD\s+COLUMN\s+\S+\s+(?!NULL|DEFAULT)/i) {
                    push @issues, {
                        severity => 'info',
                        message  => 'New column should be nullable or have a default for zero-downtime',
                        line     => $line_no,
                    };
                }
            }

            my $has_down = $content =~ /DOWN|rollback|revert/i;
            my $has_up   = $content =~ /UP|forward|migrate/i;
            my $nullable = $content !~ /SET\s+NOT\s+NULL/i || $content =~ /DEFAULT/i;
            my $concurrent = $content !~ /CREATE\s+INDEX(?!\s+CONCURRENTLY)/i;
            my $separate   = !($content =~ /BEGIN/i && $content =~ /CREATE|ALTER|DROP/i && $content =~ /INSERT|UPDATE|DELETE/i);
            my $rollback   = $has_down || $content =~ /rollback/i;

            return {
                safe    => scalar(@issues) == 0,
                issues  => \@issues,
                checklist => {
                    up_down          => $has_up && $has_down,
                    nullable_defaults => $nullable,
                    concurrent_index => $concurrent,
                    separate_data    => $separate,
                    rollback_plan    => $rollback,
                },
            };
        },
    );

    $api->register_tool(
        name        => 'migration_expand_contract',
        description => 'Generate expand-contract migration plan for a column rename',
        parameters  => {
            type       => 'object',
            properties => {
                table      => { type => 'string', description => 'Table name' },
                old_column => { type => 'string', description => 'Current column name' },
                new_column => { type => 'string', description => 'Desired column name' },
            },
            required => ['table', 'old_column', 'new_column'],
        },
        execute => sub {
            my ($args) = @_;
            my $table      = $args->{table};
            my $old_column = $args->{old_column};
            my $new_column = $args->{new_column};

            if (!$table || !$old_column || !$new_column) {
                return { error => "table, old_column, and new_column are required" };
            }

            my @phases = (
                {
                    step        => 1,
                    phase       => 'expand',
                    sql         => "ALTER TABLE $table ADD COLUMN $new_column TEXT;",
                    description => "Add new column (nullable for zero-downtime)",
                },
                {
                    step        => 2,
                    phase       => 'expand',
                    sql         => "UPDATE $table SET $new_column = $old_column WHERE $new_column IS NULL;",
                    description => "Backfill new column from old (run in batches for large tables)",
                },
                {
                    step        => 3,
                    phase       => 'contract',
                    sql         => "ALTER TABLE $table DROP COLUMN $old_column;",
                    description => "Drop old column after code migration complete",
                },
            );

            return {
                table      => $table,
                old_column => $old_column,
                new_column => $new_column,
                phases     => \@phases,
            };
        },
    );
}

1;
