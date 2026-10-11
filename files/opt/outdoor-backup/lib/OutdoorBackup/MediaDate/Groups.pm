package OutdoorBackup::MediaDate::Groups;
use strict;
use warnings;
use OutdoorBackup::MediaDate::Path ();
use OutdoorBackup::MediaDate::Date ();
use OutdoorBackup::MediaDate::Routes ();

# Stable primary rank followed by original UTF-8 byte order, never readdir order.
sub rank {
    my ($path, $meta) = @_;
    return 0 if $meta->{kind} eq 'photo' && $path !~ /\.(?:jpg|jpeg)\z/i;
    return 1 if $meta->{kind} eq 'photo';
    return 2 if $meta->{kind} eq 'video';
    return 3 if $meta->{kind} eq 'xml';
    return 4;
}
sub primary { $_[0]->{kind} eq 'photo' || $_[0]->{kind} eq 'video' }
sub stem {
    my ($path) = @_;
    $path =~ s/\.[^.\/]+\z//;
    return $path;
}
sub _warn {
    my ($warnings, $path, $code) = @_;
    $warnings->{$path}{$code} = 1;
}

# Build only current-card associations. XML uses strict exact UMID equality;
# ordinary declared sidecars use exact same-directory stem. No M01 stripping.
sub build {
    my ($metadata, $history) = @_;
    my (%owner, %stems, %videos, %warnings);
    for my $path (OutdoorBackup::MediaDate::Path::byte_sort(keys %$metadata)) {
        $owner{$path} = $path;
        my $meta = $metadata->{$path};
        _warn(\%warnings, $path, $_) for @{$meta->{warnings}};
        push @{$stems{stem($path)}}, $path if primary($meta);
        push @{$videos{$meta->{umid}}}, $path if $meta->{kind} eq 'video' && defined($meta->{umid});
    }
    my $historical = _historical_index($metadata, $history);
    _photos($metadata, \%stems, \%owner, \%warnings);
    for my $path (OutdoorBackup::MediaDate::Path::byte_sort(keys %$metadata)) {
        my $meta = $metadata->{$path};
        if ($meta->{kind} eq 'xml' && defined($meta->{umid})) {
            my $candidates = $videos{$meta->{umid}} || [];
            if (@$candidates == 1) { $owner{$path} = $owner{$candidates->[0]} }
            elsif (@$candidates > 1) { _warn(\%warnings, $path, 'ambiguous_pairing') }
        }
        if ($meta->{kind} eq 'sidecar') {
            my %groups = map { $owner{$_} => 1 } @{$stems{stem($path)} || []};
            if (keys(%groups) == 1) { ($owner{$path}) = keys %groups }
            elsif (keys(%groups) > 1) { _warn(\%warnings, $path, 'ambiguous_pairing') }
        }
        _historical_warning($path, $meta, $metadata, $history, $historical, \%owner, \%warnings);
    }
    my %groups;
    push @{$groups{$owner{$_}}}, $_ for keys %owner;
    return (\%groups, \%warnings);
}
sub _photos {
    my ($metadata, $stems, $owner, $warnings) = @_;
    for my $paths (values %$stems) {
        next unless @$paths > 1;
        my @raw = grep { $metadata->{$_}{kind} eq 'photo' && rank($_, $metadata->{$_}) == 0 } @$paths;
        my @jpeg = grep { $metadata->{$_}{kind} eq 'photo' && rank($_, $metadata->{$_}) == 1 } @$paths;
        if (@$paths == 2 && @raw == 1 && @jpeg == 1) { $owner->{$jpeg[0]} = $raw[0]; next }
        _warn($warnings, $_, 'ambiguous_pairing') for @$paths;
    }
}
# Build bounded lookups once; 50k late sidecars must not each rescan history.
sub _historical_index {
    my ($metadata, $history) = @_;
    my (%stems, %umids);
    for my $path (keys %$history) {
        next if exists($metadata->{$path});
        next unless $path =~ /\.(?:mp4|mov|m4v|arw|jpg|jpeg|dng|cr2|cr3|nef|raf|rw2|orf|tif|tiff)\z/i;
        $stems{stem($path)} = 1;
        my $identity = $history->{$path}{recording_identity};
        $umids{$identity->{signatures}{sony_umid_sha256}} = 1
            if $identity && exists($identity->{signatures}{sony_umid_sha256});
    }
    return { stems => \%stems, umids => \%umids };
}
sub _historical_warning {
    my ($path, $meta, $metadata, $history, $index, $owner, $warnings) = @_;
    return unless ($meta->{kind} eq 'sidecar' || $meta->{kind} eq 'xml') && $owner->{$path} eq $path;
    my $old_anchor = exists($history->{$path}) ? $history->{$path}{group_anchor} : undef;
    my $same_anchor = defined($old_anchor) && !exists($metadata->{$old_anchor});
    my $identity = OutdoorBackup::MediaDate::Routes::identity($meta);
    my $digest = $identity ? $identity->{signatures}{sony_umid_sha256} : undef;
    my $same_umid = defined($digest) && $index->{umids}{$digest};
    _warn($warnings, $path, 'primary_not_present') if $index->{stems}{stem($path)} || $same_anchor || $same_umid;
}

# Resolve a group's date authority. Existing main routes dominate all new date
# metadata. Any differing existing member bucket is a reclassification block.
sub decision {
    my ($members, $metadata, $history, $offset) = @_;
    my @ordered = sort { rank($a, $metadata->{$a}) <=> rank($b, $metadata->{$b})
        || OutdoorBackup::MediaDate::Path::bytes($a) cmp OutdoorBackup::MediaDate::Path::bytes($b) } @$members;
    my @mains = grep { primary($metadata->{$_}) } @ordered;
    my @existing = grep { exists($history->{$_}) } (@mains ? @mains : @ordered);
    my $anchor = @existing ? $history->{$existing[0]}{group_anchor} : $ordered[0];
    my $decision = @existing ? { bucket => $history->{$existing[0]}{bucket}, reason => $history->{$existing[0]}{date_reason} }
        : _new_decision(\@ordered, \@mains, $metadata, $offset);
    for my $path (@$members) {
        next unless exists($history->{$path});
        die "reclassification_required\n" if $history->{$path}{bucket} ne $decision->{bucket};
    }
    return { %$decision, anchor => $anchor };
}
sub _new_decision {
    my ($ordered, $mains, $metadata, $offset) = @_;
    my @authorities = @$mains ? @$mains : ($ordered->[0]);
    my @decisions;
    for my $path (@authorities) {
        my @dates = @{$metadata->{$path}{dates}};
        if ($metadata->{$path}{kind} eq 'video') {
            for my $peer (@$ordered) {
                next unless $metadata->{$peer}{kind} eq 'xml';
                push @dates, map { { %$_, priority => 20 } } @{$metadata->{$peer}{dates}};
            }
        }
        push @decisions, OutdoorBackup::MediaDate::Date::choose(\@dates, $offset);
    }
    my @valid = grep { $_->{primary} } @decisions;
    return $decisions[0] unless @valid;
    my $decision = $valid[0];
    for my $peer (@valid) {
        return $peer if $peer->{bucket} eq 'Undated';
        my $reason = OutdoorBackup::MediaDate::Date::compare($decision->{primary}, $peer->{primary});
        return { bucket => 'Undated', reason => $reason } if $reason;
    }
    return $decision;
}
1;
