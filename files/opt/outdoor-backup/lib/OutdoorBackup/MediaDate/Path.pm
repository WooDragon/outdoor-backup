package OutdoorBackup::MediaDate::Path;
use strict;
use warnings;
use Encode qw(encode decode FB_CROAK);
use OutdoorBackup::MediaDate::JSON ();

# Canonical UUID shape preserves the logical namespace hex case.
sub uuid {
    my ($value) = @_;
    die "invalid_uuid\n" unless OutdoorBackup::MediaDate::JSON::string($value)
        && $value =~ /\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/;
    return $value;
}

# Preserve UTF-8 text, including whitespace and normalization differences.
sub relative {
    my ($path) = @_;
    die "invalid_relative_path\n" unless OutdoorBackup::MediaDate::JSON::string($path)
        && length($path) && $path !~ /\x00/;
    my @parts = split m{/}, $path, -1;
    for my $part (@parts) {
        die "invalid_path_component\n" if $part eq '' || $part eq '.' || $part eq '..';
        die "reserved_partial_component\n" if $part eq '.rsync-partial';
    }
    encode('UTF-8', $path, FB_CROAK | Encode::LEAVE_SRC());
    return $path;
}
sub bytes { encode('UTF-8', $_[0], FB_CROAK | Encode::LEAVE_SRC()) }
sub text { decode('UTF-8', $_[0], FB_CROAK | Encode::LEAVE_SRC()) }
sub byte_sort { sort { bytes($a) cmp bytes($b) } @_ }

# Absolute input roots may include /proc/<owner>/fd/9 for the FD-anchored target.
# Parent anchoring and root ownership remain manager responsibilities.
sub absolute {
    my ($path) = @_;
    die "invalid_absolute_path\n" unless OutdoorBackup::MediaDate::JSON::string($path)
        && $path =~ m{\A/} && $path !~ /\x00/;
    die "invalid_absolute_path\n" if $path ne '/' && $path =~ m{(?:/\.?\.?/|/\.?\.?\z|//)};
    return $path;
}

# Validate all leaf and directory-prefix collisions, including historical rows.
sub collisions {
    my ($entries) = @_;
    my (%leaves, %parents);
    for my $entry (values %$entries) {
        my $target = $entry->{target_relpath};
        die "target_leaf_collision\n" if $leaves{$target}++;
        my @parts = split '/', $target;
        pop @parts;
        while (@parts) {
            $parents{join('/', @parts)} = 1;
            pop @parts;
        }
    }
    die "target_prefix_collision\n" if grep { $parents{$_} } keys %leaves;
}

# Every existing intermediate component must be a real directory. A leaf
# may only be a regular file owned by the same historical source path.
sub target_check {
    my ($root, $target, $registered) = @_;
    my @parts = split '/', $target;
    my $leaf = pop @parts;
    my $path = bytes($root);
    for my $part (@parts) {
        $path .= '/' . bytes($part);
        my @st = lstat($path);
        die "target_stat_failed: $!\n" if !@st && !$!{ENOENT};
        next unless @st;
        die "target_component_conflict\n" if -l _ || !-d _;
    }
    $path .= '/' . bytes($leaf);
    my @st = lstat($path);
    die "target_stat_failed: $!\n" if !@st && !$!{ENOENT};
    return unless @st;
    die "foreign_target\n" unless $registered;
    die "target_leaf_type_conflict\n" if -l _ || !-f _;
}
1;
