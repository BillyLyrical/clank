# Clam::Taxonomy — hierarchical classification for entities, beliefs, and goals.
#
# Provides inheritance: child categories inherit properties from parents.
# Properties override at deeper levels. Enables category-aware queries
# across the world model.
#
# Design:
#   - Categories form a tree via parent_id
#   - Each category can have key-value properties (inherited)
#   - Entities, beliefs, and goals map to categories
#   - Queries traverse the tree to collect inherited properties
package Clam::Taxonomy;
use strict;
use warnings;
use Clam::Util qw(now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $world_model = $args{world_model} or die "Clam::Taxonomy requires world_model\n";

    my $self = bless {
        world_model => $world_model,
        dbh         => $world_model->{dbh},
        bus         => $args{bus},
        metrics     => $args{metrics},
    }, $class;
    $self->_init_schema;
    return $self;
}

sub _dbh { $_[0]->{dbh} }

sub _init_schema {
    my ($self) = @_;
    my $db = $self->_dbh;

    $db->do(qq{
CREATE TABLE IF NOT EXISTS taxonomy_nodes (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    parent_id   TEXT,
    type        TEXT NOT NULL,
    description TEXT,
    created_at  INTEGER,
    updated_at  INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_taxo_parent ON taxonomy_nodes(parent_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_taxo_type ON taxonomy_nodes(type)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS taxonomy_props (
    node_id   TEXT NOT NULL REFERENCES taxonomy_nodes(id) ON DELETE CASCADE,
    key       TEXT NOT NULL,
    value     TEXT,
    PRIMARY KEY (node_id, key)
)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS taxonomy_map (
    entity_id TEXT,
    belief_id INTEGER,
    goal_id   TEXT,
    node_id   TEXT NOT NULL REFERENCES taxonomy_nodes(id) ON DELETE CASCADE,
    PRIMARY KEY (entity_id, belief_id, goal_id, node_id)
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_taxo_map_entity ON taxonomy_map(entity_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_taxo_map_belief ON taxonomy_map(belief_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_taxo_map_goal ON taxonomy_map(goal_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_taxo_map_node ON taxonomy_map(node_id)});
}

# === CATEGORY MANAGEMENT ===

sub create_category {
    my ($self, %args) = @_;
    my $id = $args{id} || _gen_id();
    my $now = now_ms();

    # Validate parent exists if specified.
    if ($args{parent_id}) {
        my $parent = $self->_dbh->selectrow_hashref(
            'SELECT id FROM taxonomy_nodes WHERE id = ?', undef, $args{parent_id});
        die "parent category '$args{parent_id}' not found\n" unless $parent;
    }

    $self->_dbh->do(
        'INSERT INTO taxonomy_nodes (id, name, parent_id, type, description, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)',
        undef, $id, $args{name}, $args{parent_id},
        $args{type} // 'general', $args{description},
        $now, $now,
    );
    return $id;
}

sub get_category {
    my ($self, $id) = @_;
    return $self->_dbh->selectrow_hashref(
        'SELECT * FROM taxonomy_nodes WHERE id = ?', undef, $id);
}

sub update_category {
    my ($self, $id, %args) = @_;
    my $now = now_ms();
    my @sets = ('updated_at = ?');
    my @bind = ($now);

    for my $field (qw(name parent_id description)) {
        if (defined $args{$field}) {
            push @sets, "$field = ?";
            push @bind, $args{$field};
        }
    }
    push @bind, $id;
    $self->_dbh->do(
        'UPDATE taxonomy_nodes SET ' . join(', ', @sets) . ' WHERE id = ?',
        undef, @bind);
}

sub delete_category {
    my ($self, $id) = @_;
    # Move children to parent (or orphan them).
    my $cat = $self->get_category($id);
    if ($cat) {
        $self->_dbh->do(
            'UPDATE taxonomy_nodes SET parent_id = ? WHERE parent_id = ?',
            undef, $cat->{parent_id}, $id);
    }
    $self->_dbh->do('DELETE FROM taxonomy_nodes WHERE id = ?', undef, $id);
}

sub children {
    my ($self, $parent_id) = @_;
    return $self->_dbh->selectall_arrayref(
        'SELECT * FROM taxonomy_nodes WHERE parent_id = ? ORDER BY name',
        { Slice => {} }, $parent_id);
}

sub root_categories {
    my ($self, %args) = @_;
    my $type = $args{type};
    my ($sql, @bind) = ('SELECT * FROM taxonomy_nodes WHERE parent_id IS NULL');
    if ($type) {
        $sql .= ' AND type = ?';
        push @bind, $type;
    }
    $sql .= ' ORDER BY name';
    return $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

# === PATH QUERIES ===

# Get full path from root to a node: [{ id, name }, ...].
sub ancestors {
    my ($self, $node_id) = @_;
    my @path;
    my $current = $node_id;
    my %seen;

    while ($current) {
        last if $seen{$current}++;  # cycle guard
        my $cat = $self->get_category($current);
        last unless $cat;
        unshift @path, { id => $cat->{id}, name => $cat->{name} };
        $current = $cat->{parent_id};
    }
    return \@path;
}

# Get all descendants of a node (BFS).
sub descendants {
    my ($self, $node_id, %args) = @_;
    my $max_depth = $args{max_depth} // 10;

    my @result;
    my %visited = ($node_id => 1);
    my @queue = ([ $node_id, 0 ]);

    while (@queue) {
        my ($current, $depth) = @{ shift @queue };
        next if $depth >= $max_depth;

        my $kids = $self->children($current);
        for my $kid (@$kids) {
            next if $visited{$kid->{id}}++;
            push @result, { id => $kid->{id}, name => $kid->{name}, depth => $depth + 1 };
            push @queue, [ $kid->{id}, $depth + 1 ];
        }
    }
    return \@result;
}

# === PROPERTY INHERITANCE ===

sub set_property {
    my ($self, %args) = @_;
    $self->_dbh->do(
        'INSERT OR REPLACE INTO taxonomy_props (node_id, key, value) VALUES (?, ?, ?)',
        undef, $args{node_id}, $args{key}, $args{value});
}

sub get_property {
    my ($self, %args) = @_;
    my $row = $self->_dbh->selectrow_hashref(
        'SELECT value FROM taxonomy_props WHERE node_id = ? AND key = ?',
        undef, $args{node_id}, $args{key});
    return $row ? $row->{value} : undef;
}

sub delete_property {
    my ($self, %args) = @_;
    $self->_dbh->do(
        'DELETE FROM taxonomy_props WHERE node_id = ? AND key = ?',
        undef, $args{node_id}, $args{key});
}

sub all_properties {
    my ($self, $node_id) = @_;
    my $rows = $self->_dbh->selectall_arrayref(
        'SELECT key, value FROM taxonomy_props WHERE node_id = ?',
        { Slice => {} }, $node_id);
    my %props = map { $_->{key} => $_->{value} } @$rows;
    return \%props;
}

# Get all properties for a node, including inherited ones from ancestors.
# Child properties override parent properties.
sub inherited_properties {
    my ($self, $node_id) = @_;
    my $ancestors = $self->ancestors($node_id);

    my %props;
    for my $anc (@$ancestors) {
        my $p = $self->all_properties($anc->{id});
        %props = (%props, %$p);  # child overrides parent
    }

    # Also include the node's own properties (highest priority).
    my $own = $self->all_properties($node_id);
    %props = (%props, %$own);

    return \%props;
}

# === MAPPING: entities/beliefs/goals → categories ===

sub map_entity {
    my ($self, %args) = @_;
    $self->_dbh->do(
        'INSERT OR IGNORE INTO taxonomy_map (entity_id, goal_id, belief_id, node_id) VALUES (?, NULL, NULL, ?)',
        undef, $args{entity_id}, $args{node_id});
}

sub map_belief {
    my ($self, %args) = @_;
    $self->_dbh->do(
        'INSERT OR IGNORE INTO taxonomy_map (entity_id, goal_id, belief_id, node_id) VALUES (NULL, NULL, ?, ?)',
        undef, $args{belief_id}, $args{node_id});
}

sub map_goal {
    my ($self, %args) = @_;
    $self->_dbh->do(
        'INSERT OR IGNORE INTO taxonomy_map (entity_id, goal_id, belief_id, node_id) VALUES (NULL, ?, NULL, ?)',
        undef, $args{goal_id}, $args{node_id});
}

sub unmap {
    my ($self, %args) = @_;
    if ($args{entity_id}) {
        $self->_dbh->do(
            'DELETE FROM taxonomy_map WHERE entity_id = ? AND node_id = ?',
            undef, $args{entity_id}, $args{node_id});
    }
    if ($args{belief_id}) {
        $self->_dbh->do(
            'DELETE FROM taxonomy_map WHERE belief_id = ? AND node_id = ?',
            undef, $args{belief_id}, $args{node_id});
    }
    if ($args{goal_id}) {
        $self->_dbh->do(
            'DELETE FROM taxonomy_map WHERE goal_id = ? AND node_id = ?',
            undef, $args{goal_id}, $args{node_id});
    }
}

# === CATEGORY-AWARE QUERIES ===

# Find all entities under a category (including descendants).
sub entities_in_category {
    my ($self, $node_id, %args) = @_;
    my $limit = $args{limit} // 100;

    my $desc = $self->descendants($node_id);
    my @node_ids = ($node_id, map { $_->{id} } @$desc);
    return [] unless @node_ids;

    my $placeholders = join(',', ('?') x @node_ids);
    return $self->_dbh->selectall_arrayref(
        "SELECT DISTINCT e.* FROM wm_entities e
         JOIN taxonomy_map tm ON tm.entity_id = e.id
         WHERE tm.node_id IN ($placeholders)
         LIMIT $limit",
        { Slice => {} }, @node_ids);
}

# Find all beliefs under a category (including descendants).
sub beliefs_in_category {
    my ($self, $node_id, %args) = @_;
    my $limit = $args{limit} // 100;
    my $min_confidence = $args{min_confidence} // 0;

    my $desc = $self->descendants($node_id);
    my @node_ids = ($node_id, map { $_->{id} } @$desc);
    return [] unless @node_ids;

    my $placeholders = join(',', ('?') x @node_ids);
    return $self->_dbh->selectall_arrayref(
        "SELECT DISTINCT b.* FROM wm_beliefs b
         JOIN taxonomy_map tm ON tm.belief_id = b.id
         WHERE tm.node_id IN ($placeholders)
           AND b.superseded_by IS NULL
           AND b.confidence >= ?
         ORDER BY b.confidence DESC
         LIMIT $limit",
        { Slice => {} }, @node_ids, $min_confidence);
}

# Find all goals under a category (including descendants).
sub goals_in_category {
    my ($self, $node_id, %args) = @_;
    my $limit = $args{limit} // 100;
    my $status = $args{status};

    my $desc = $self->descendants($node_id);
    my @node_ids = ($node_id, map { $_->{id} } @$desc);
    return [] unless @node_ids;

    my $placeholders = join(',', ('?') x @node_ids);
    my ($extra_where, @extra_bind) = ('', );
    if ($status) {
        $extra_where = ' AND g.status = ?';
        push @extra_bind, $status;
    }

    return $self->_dbh->selectall_arrayref(
        "SELECT DISTINCT g.* FROM goals g
         JOIN taxonomy_map tm ON tm.goal_id = g.id
         WHERE tm.node_id IN ($placeholders)$extra_where
         ORDER BY g.priority ASC
         LIMIT $limit",
        { Slice => {} }, @node_ids, @extra_bind);
}

# Find which categories an entity belongs to (including ancestors).
sub entity_categories {
    my ($self, $entity_id) = @_;
    my $rows = $self->_dbh->selectall_arrayref(
        'SELECT node_id FROM taxonomy_map WHERE entity_id = ?',
        { Slice => {} }, $entity_id);

    my %all_cats;
    for my $r (@$rows) {
        my $ancestors = $self->ancestors($r->{node_id});
        for my $a (@$ancestors) {
            $all_cats{$a->{id}} = $a->{name};
        }
    }

    return [ map { { id => $_, name => $all_cats{$_} } } sort keys %all_cats ];
}

# Find which categories a belief belongs to (including ancestors).
sub belief_categories {
    my ($self, $belief_id) = @_;
    my $rows = $self->_dbh->selectall_arrayref(
        'SELECT node_id FROM taxonomy_map WHERE belief_id = ?',
        { Slice => {} }, $belief_id);

    my %all_cats;
    for my $r (@$rows) {
        my $ancestors = $self->ancestors($r->{node_id});
        for my $a (@$ancestors) {
            $all_cats{$a->{id}} = $a->{name};
        }
    }

    return [ map { { id => $_, name => $all_cats{$_} } } sort keys %all_cats ];
}

# Check if an entity/belief/goal is under a specific category (including via ancestors).
sub entity_under_category {
    my ($self, $entity_id, $node_id) = @_;
    my $cats = $self->entity_categories($entity_id);
    return scalar grep { $_->{id} eq $node_id } @$cats;
}

# === INHERITANCE-AWARE CONSTRAINT CHECK ===

# Check if a node or its ancestors have a specific property.
sub has_property_inherited {
    my ($self, $node_id, $key) = @_;
    my $ancestors = $self->ancestors($node_id);
    for my $a (@$ancestors) {
        my $val = $self->get_property(node_id => $a->{id}, key => $key);
        return $val if defined $val;
    }
    my $own = $self->get_property(node_id => $node_id, key => $key);
    return $own;
}

# === STATISTICS ===

sub stats {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    return {
        categories  => $dbh->selectrow_array('SELECT COUNT(*) FROM taxonomy_nodes'),
        properties  => $dbh->selectrow_array('SELECT COUNT(*) FROM taxonomy_props'),
        mappings    => $dbh->selectrow_array('SELECT COUNT(*) FROM taxonomy_map'),
        roots       => $dbh->selectrow_array('SELECT COUNT(*) FROM taxonomy_nodes WHERE parent_id IS NULL'),
        leaf_count  => $dbh->selectrow_array(
            'SELECT COUNT(*) FROM taxonomy_nodes WHERE id NOT IN (SELECT DISTINCT parent_id FROM taxonomy_nodes WHERE parent_id IS NOT NULL)'),
    };
}

sub _gen_id {
    my @chars = ('a'..'z', '0'..'9');
    return join '', map { $chars[int(rand(@chars))] } 1..12;
}

1;

__END__

=head1 NAME

Clam::Taxonomy — hierarchical classification for entities, beliefs, and goals.

=head1 SYNOPSIS

  use Clam::Taxonomy;

  my $tx = Clam::Taxonomy->new(
      world_model => $wm,             # required: Clam::WorldModel
      bus         => $bus,            # optional
      metrics     => $metrics,        # optional
  );

  # Build category tree
  my $lang = $tx->create_category(name => 'language', type => 'entity_type');
  my $script = $tx->create_category(name => 'scripting', type => 'entity_type',
                                    parent_id => $lang);
  my $compiled = $tx->create_category(name => 'compiled', type => 'entity_type',
                                      parent_id => $lang);

  # Inheritable properties
  $tx->set_property(node_id => $lang, key => 'typed', value => 'yes');
  my $props = $tx->inherited_properties($script);  # { typed => 'yes' }

  # Map world model items to categories
  $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
  $tx->map_entity(entity_id => 'perl', node_id => $script);

  # Category-aware queries
  my $entities = $tx->entities_in_category($lang);    # all languages
  my $beliefs  = $tx->beliefs_in_category($factual);  # all factual beliefs
  my $goals    = $tx->goals_in_category($learn);      # all learning goals

  # Check membership (traverses ancestors)
  $tx->entity_under_category('perl', $lang);  # true

=head1 DESCRIPTION

Clam::Taxonomy provides hierarchical classification across the world model.
Entities, beliefs, and goals map to categories in a tree. Properties on
categories are inherited by children (child overrides parent).

The taxonomy enables:

=over 4

=item Inheritance — child categories inherit properties from parents.

=item Scope control — query at any level of the hierarchy.

=item Category-aware queries — find all entities/beliefs/goals under a branch.

=item Constraint propagation — rules apply to entire categories.

=item Reasoning efficiency — reason about categories, not individuals.

=back

=head1 SCHEMA

=over 4

=item taxonomy_nodes — id, name, parent_id, type, description

=item taxonomy_props — node_id, key, value (inherited)

=item taxonomy_map — entity_id|belief_id|goal_id -> node_id

=back

=head1 METHODS

=head2 create_category(%args)

Create a category. Required: C<name>. Optional: C<type>, C<parent_id>, C<description>.
Dies if C<parent_id> does not exist.

=head2 descendants($node_id, max_depth => $n)

BFS traversal of all descendant categories. Returns arrayref of
C<{ id, name, depth }>.

=head2 ancestors($node_id)

Path from root to node. Returns arrayref of C<{ id, name }> in root-first order.

=head2 inherited_properties($node_id)

All properties for a node including inherited ones from ancestors.
Child properties override parent.

=head2 entities_in_category($node_id)

All entities mapped to this category or any descendant.

=head2 beliefs_in_category($node_id, min_confidence => $n)

All beliefs mapped to this category or any descendant.

=head2 entity_under_category($entity_id, $node_id)

Check if an entity belongs to a category (traverses ancestors).

=cut
