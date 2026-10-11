package OutdoorBackup::MediaDate::Routes;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use OutdoorBackup::MediaDate::JSON ();
use OutdoorBackup::MediaDate::Path ();
use OutdoorBackup::MediaDate::Date ();

our @IDENTITY_TYPES = qw(sony_umid_sha256 exif_capture_sha256 sony_xml_capture_sha256 dji_oa5_capture_sha256);
our @REASONS = qw(no_capture_date exif_capture sony_xml_capture dji_oa5_capture
    conflicting_capture_date ambiguous_date_semantics);

# Library policy is immutable; exact schema and integer (not numeric string).
sub library {
    my ($object) = @_;
    OutdoorBackup::MediaDate::JSON::exact($object, qw(version library_id layout parser_profile archive_offset_minutes));
    die "unknown_library_version\n" unless OutdoorBackup::MediaDate::JSON::integer($object->{version}) && $object->{version} == 1;
    OutdoorBackup::MediaDate::Path::uuid($object->{library_id});
    die "unknown_library_profile\n" unless OutdoorBackup::MediaDate::JSON::string($object->{layout})
        && OutdoorBackup::MediaDate::JSON::string($object->{parser_profile})
        && $object->{layout} eq 'date' && $object->{parser_profile} eq 'media-date-v1';
    die "invalid_archive_offset\n" unless OutdoorBackup::MediaDate::JSON::integer($object->{archive_offset_minutes})
        && abs($object->{archive_offset_minutes}) <= 840;
    return $object;
}
sub identity_schema {
    my ($identity) = @_;
    return unless defined $identity;
    OutdoorBackup::MediaDate::JSON::exact($identity, qw(version signatures));
    die "invalid_identity_version\n" unless OutdoorBackup::MediaDate::JSON::integer($identity->{version}) && $identity->{version} == 1;
    my $signatures = $identity->{signatures};
    die "invalid_identity_signatures\n" unless ref($signatures) eq 'HASH' && keys(%$signatures);
    my %allowed = map { $_ => 1 } @IDENTITY_TYPES;
    for my $type (keys %$signatures) {
        die "invalid_identity_type\n" unless $allowed{$type};
        die "invalid_identity_digest\n" unless OutdoorBackup::MediaDate::JSON::string($signatures->{$type})
            && $signatures->{$type} =~ /\A[0-9a-f]{64}\z/;
    }
}

# Validate snapshot including all historical targets and anchors (which must
# be registered paths in the same snapshot, including deleted source files).
sub validate {
    my ($object, $library_id, $source_id) = @_;
    OutdoorBackup::MediaDate::Path::uuid($library_id);
    OutdoorBackup::MediaDate::Path::uuid($source_id);
    OutdoorBackup::MediaDate::JSON::exact($object, qw(version library_id source_id entries));
    die "unknown_routes_version\n" unless OutdoorBackup::MediaDate::JSON::integer($object->{version}) && $object->{version} == 1;
    die "routes_identity_mismatch\n" unless OutdoorBackup::MediaDate::JSON::string($object->{library_id})
        && OutdoorBackup::MediaDate::JSON::string($object->{source_id})
        && $object->{library_id} eq $library_id && $object->{source_id} eq $source_id;
    die "invalid_routes_entries\n" unless ref($object->{entries}) eq 'HASH';
    my %reasons = map { $_ => 1 } @REASONS;
    for my $path (keys %{$object->{entries}}) {
        OutdoorBackup::MediaDate::Path::relative($path);
        my $entry = $object->{entries}{$path};
        OutdoorBackup::MediaDate::JSON::exact($entry, qw(group_anchor recording_identity bucket date_reason target_relpath));
        OutdoorBackup::MediaDate::Path::relative($entry->{group_anchor});
        die "missing_group_anchor\n" unless exists($object->{entries}{$entry->{group_anchor}});
        identity_schema($entry->{recording_identity});
        die "invalid_date_bucket\n" unless OutdoorBackup::MediaDate::Date::valid_bucket($entry->{bucket});
        die "invalid_date_reason\n" unless OutdoorBackup::MediaDate::JSON::string($entry->{date_reason}) && $reasons{$entry->{date_reason}};
        OutdoorBackup::MediaDate::Path::relative($entry->{target_relpath});
        die "invalid_route_target\n" unless $entry->{target_relpath} eq "$entry->{bucket}/$source_id/$path";
    }
    for my $entry (values %{$object->{entries}}) {
        my $anchor = $object->{entries}{$entry->{group_anchor}};
        die "invalid_group_anchor\n" unless $anchor->{bucket} eq $entry->{bucket};
    }
    OutdoorBackup::MediaDate::Path::collisions($object->{entries});
    return $object;
}

# Only recording fields are digested, never file content. Capture signatures
# intentionally use whole native seconds: adding offset/subseconds enriches
# metadata, not evidence of another recording. Different types coexist.
sub identity {
    my ($metadata) = @_;
    my %signatures;
    if (defined($metadata->{umid})) {
        $signatures{sony_umid_sha256} = sha256_hex(OutdoorBackup::MediaDate::Path::bytes($metadata->{umid}));
    }
    my %bases;
    for my $date (@{$metadata->{dates}}) {
        next unless OutdoorBackup::MediaDate::Date::parse($date, 0);
        next unless $date->{value} =~ /\A(\d{4})[:-](\d\d)[:-](\d\d)[T ](\d\d:\d\d:\d\d)/;
        $bases{$date->{field}}{"$1-$2-$3" . "T$4"} = 1;
    }
    for my $field (keys %bases) {
        next unless keys(%{$bases{$field}}) == 1;
        my ($base) = keys %{$bases{$field}};
        $signatures{"${field}_sha256"} = sha256_hex("media-date-v1\0$field\0$base");
    }
    return keys(%signatures) ? { version => 1, signatures => \%signatures } : undef;
}

# Reject a changed shared signature; preserve missing historical types and add
# newly observed types. This supports identity enrichment without moving days.
sub merge_identity {
    my ($old, $new) = @_;
    return $old unless $new;
    return $new unless $old;
    my %merged = %{$old->{signatures}};
    for my $type (keys %{$new->{signatures}}) {
        die "source_slot_reused\n" if exists($merged{$type}) && $merged{$type} ne $new->{signatures}{$type};
        $merged{$type} = $new->{signatures}{$type};
    }
    return { version => 1, signatures => \%merged };
}
1;
