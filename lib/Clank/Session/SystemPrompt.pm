package Clank::Session::SystemPrompt;
use strict; use warnings;
# Verbatim port of pi's buildSystemPrompt (packages/coding-agent/src/core/system-prompt.ts)
# + formatSkillsForPrompt (skills.ts). Paths point at clank's own docs.

sub escape_xml { my ($s)=@_; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; return $s; }

sub format_skills_for_prompt {
    my (@skills) = @_;
    @skills = grep { !($_->{disable_model_invocation}) } @skills;
    return "" unless @skills;
    my @lines = (
        "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Use the read tool to load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
        "",
        "<available_skills>",
    );
    for my $s (@skills) {
        push @lines, "  <skill>",
            sprintf("    <name>%s</name>", escape_xml($s->{name})),
            sprintf("    <description>%s</description>", escape_xml($s->{description})),
            sprintf("    <location>%s</location>", escape_xml($s->{file_path})),
            "  </skill>";
    }
    push @lines, "</available_skills>";
    return join("\n", @lines);
}

sub build {
    my (%o) = @_;
    my $cwd          = ($o{cwd} // '.'); $cwd =~ s/\\/ /g; $cwd =~ s{\\}{/}g;
    my $custom       = $o{custom_prompt};
    my @tools        = @{ $o{selected_tools} // ['read','bash','edit','write'] };
    my %snippets     = %{ $o{tool_snippets} // {} };
    my @guidelines   = @{ $o{prompt_guidelines} // [] };
    my $append       = $o{append_system_prompt};
    my @context_files= @{ $o{context_files} // [] };
    my @skills       = @{ $o{skills} // [] };

    my $append_section = defined $append ? "\n\n$append" : "";

    if (defined $custom) {
        my $prompt = $custom . $append_section;
        if (@context_files) {
            $prompt .= "\n\n<project_context>\n\nProject-specific instructions and guidelines:\n\n";
            for my $f (@context_files) {
                $prompt .= qq{<project_instructions path="$f->{path}">\n$f->{content}\n</project_instructions>\n\n};
            }
            $prompt .= "</project_context>\n";
        }
        my $has_read = grep { $_ eq 'read' } @tools;
        $prompt .= format_skills_for_prompt(@skills) if $has_read && @skills;
        return $prompt . "\nCurrent working directory: $cwd\n";
    }

    my $docs_dir     = $o{docs_dir}     // '/PATH/TO/Clank/docs';
    my $examples_dir = $o{examples_dir} // '/PATH/TO/Clank/wits.example';

    my @visible = grep { defined $snippets{$_} } @tools;
    my $tools_list = @visible ? join("\n", map { "- $_: " . $snippets{$_} } @visible) : "(none)";

    my (@gl, %seen);
    my $add = sub { return if $seen{ $_[0] }++; push @gl, $_[0]; };
    my $has_bash  = grep { $_ eq 'bash' } @tools;
    $add->("Use bash for file operations like ls, rg, find") if $has_bash;
    $add->($_) for map { s/^\s+|\s+$//gr } @guidelines;
    $add->("Be concise in your responses");
    $add->("Show file paths clearly when working with files");
    my $guidelines = join("\n", map { "- $_" } @gl);

    my $prompt = <<"EOT";
You are an expert coding assistant operating inside clank, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
$tools_list

In addition to the tools above, you may have access to other custom tools depending on the project.

Guidelines:
$guidelines

Clank documentation (read only when the user asks about clank itself, its SDK, wits, skills, or providers):
- Main documentation: $docs_dir/ROADMAP.md
- Wits examples: $examples_dir
- When asked about: wits (docs/ROADMAP.md §5), skills (docs/Wits.md), providers (§2.1), logic (§7)
- Also read: docs/Wits.md (wit implementation spec), docs/DRIVER.md (daemon/SDK docs)
- Always read clank .md files completely and follow links to related docs
EOT

    $prompt .= $append_section;
    if (@context_files) {
        $prompt .= "\n\n<project_context>\n\nProject-specific instructions and guidelines:\n\n";
        for my $f (@context_files) {
            $prompt .= qq{<project_instructions path="$f->{path}">\n$f->{content}\n</project_instructions>\n\n};
        }
        $prompt .= "</project_context>\n";
    }
    my $has_read = grep { $_ eq 'read' } @tools;
    $prompt .= format_skills_for_prompt(@skills) if $has_read && @skills;
    return $prompt . "\nCurrent working directory: $cwd";
}

1;
