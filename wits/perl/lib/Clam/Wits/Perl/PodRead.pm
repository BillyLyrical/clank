# CLAM-WIT: name=PodRead
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Read Perl module POD: extract subs, docs, interface
# CLAM-WIT: usage=Input: { module: "Clam::Memory" } or { file: "/path/to/Module.pm", subs: 1 } Output: { subs: [...], pod: "...", stats: {...} }
# CLAM-WIT: hint=pod_read, POD reader, module interface, extract subs
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Perl::PodRead;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'pod_read',
        description => 'Read Perl module POD: extract subs, docs, interface',
        parameters  => {
            type       => 'object',
            properties => {
                module  => { type => 'string', description => 'Module name (e.g. Clam::Memory)' },
                file    => { type => 'string', description => 'File path to module' },
                section => { type => 'string', description => 'POD section to extract' },
                subs    => { type => 'boolean', description => 'Extract only sub signatures' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $module = $args->{module} // '';
            my $file = $args->{file} // '';
            my $section = $args->{section} // '';
            my $grep_mode = $args->{subs} // 0;

            if ($module && !$file) {
                my $path = $module;
                $path =~ s{::}{/}g;
                $path .= ".pm";
                for my $dir (@INC) {
                    my $try = "$dir/$path";
                    if (-f $try) { $file = $try; last; }
                }
                return { error => "Module not found: $module", searched => \@INC } unless $file;
            }

            return { error => "No module or file specified" } unless $file;
            return { error => "File not found: $file" } unless -f $file;

            open my $fh, '<', $file or return { error => "Cannot read: $file" };
            my @lines = <$fh>;
            close $fh;
            chomp @lines;

            my @subs;
            for my $i (0..$#lines) {
                my $line = $lines[$i];
                if ($line =~ /^(?:my\s+)?sub\s+(\w+)/) {
                    my $name = $1;
                    my @sig_lines;
                    for my $j ($i+1..$i+5) {
                        last unless defined $lines[$j];
                        my $l = $lines[$j];
                        $l =~ s/^\s+//;
                        push @sig_lines, $l;
                        last if $l =~ /\{/;
                    }
                    push @subs, {
                        name => $name,
                        line => $i + 1,
                        sig  => join(" ", @sig_lines),
                    };
                }
            }

            my @pod;
            my $in_pod = 0;
            my $current_section = '';
            my %pod_sections;

            for my $line (@lines) {
                if ($line =~ /^=(\w+)/) {
                    $in_pod = 1;
                    $current_section = $1;
                    push @pod, $line;
                    next;
                }
                if ($line =~ /^=cut/) {
                    $in_pod = 0;
                    push @pod, $line;
                    next;
                }
                if ($in_pod) {
                    push @pod, $line;
                    $pod_sections{$current_section} //= [];
                    push @{$pod_sections{$current_section}}, $line;
                }
            }

            my $pod_text = join("\n", @pod);

            if ($section && $pod_sections{$section}) {
                $pod_text = join("\n", @{$pod_sections{$section}});
            }

            my $total_lines = scalar @lines;
            my $pod_lines = scalar @pod;
            my $code_lines = $total_lines - $pod_lines - 1;

            return {
                topic    => 'pod.read',
                module   => $module,
                file     => $file,
                subs     => \@subs,
                sub_count => scalar @subs,
                pod      => $pod_text,
                pod_sections => [sort keys %pod_sections],
                stats    => {
                    total_lines => $total_lines,
                    code_lines  => $code_lines,
                    pod_lines   => $pod_lines,
                    sub_count   => scalar @subs,
                },
            };
        },
    );
}

1;
