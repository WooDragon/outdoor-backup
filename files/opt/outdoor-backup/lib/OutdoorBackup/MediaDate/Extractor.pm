package OutdoorBackup::MediaDate::Extractor;
use strict;
use warnings;
use Image::ExifTool ();
use OutdoorBackup::MediaDate::JSON ();
use OutdoorBackup::MediaDate::Path ();

our $MAX_XML = 8 * 1024 * 1024;
our @TAGS = qw(EXIF:DateTimeOriginal EXIF:SubSecTimeOriginal EXIF:OffsetTimeOriginal
    QuickTime:CreateDate QuickTime:Encoder CreationDateValue TargetMaterialUmidRef
    DeviceModelName NonRealTimeMetaCreationDateValue NonRealTimeMetaTargetMaterialUmidRef
    NonRealTimeMetaDeviceModelName Warning Error);

# One reusable reader, -fast (never fast2, ee, full dump, or shell).
sub new {
    my ($class) = @_;
    my $tool = Image::ExifTool->new;
    $tool->Options(FastScan => 1, ExtractEmbedded => 0, QuickTimeUTC => 0, Duplicates => 1);
    return bless { tool => $tool }, $class;
}
sub kind {
    my ($path) = @_;
    return 'photo' if $path =~ /\.(?:arw|jpg|jpeg|dng|cr2|cr3|nef|raf|rw2|orf|tif|tiff)\z/i;
    return 'video' if $path =~ /\.(?:mp4|mov|m4v)\z/i;
    return 'xml' if $path =~ /\.xml\z/i;
    return 'sidecar' if $path =~ /\.(?:srt|lrf|thm)\z/i;
    return 'other';
}

# Extract one ordinary file; normalized output has no GPS/serial/full XML.
# Raw UMID exists only in private memory for strict pairing, never in routes.
sub extract {
    my ($self, $path) = @_;
    my $kind = kind($path);
    my $empty = { version => 1, kind => $kind, dates => [], umid => undef, warnings => [] };
    return $empty if $kind eq 'other' || $kind eq 'sidecar';
    my $bytes = OutdoorBackup::MediaDate::Path::bytes($path);
    my @st = lstat($bytes);
    die "source_not_regular\n" unless @st && !-l _ && -f _;
    if ($kind eq 'xml' && $st[7] > $MAX_XML) {
        push @{$empty->{warnings}}, 'xml_too_large';
        return $empty;
    }
    my $tool = $self->{tool};
    $tool->ExtractInfo($bytes, @TAGS) or do {
        push @{$empty->{warnings}}, 'metadata_parse_failed';
        return $empty;
    };
    my $info = $tool->GetInfo(@TAGS);
    my %tags;
    for my $key (sort keys %$info) {
        my $name = Image::ExifTool::GetTagName($key);
        my $value = $info->{$key};
        next if ref($value) || !defined($value);
        push @{$tags{$name}}, "$value";
    }
    return normalize($kind, \%tags);
}

# API test doubles must use exactly this raw whitelist, then pass through this
# same normalization method; arbitrary invented date schemas are not accepted.
sub normalize {
    my ($kind, $tags) = @_;
    my %allowed = map { (s/^.*://r) => 1 } @TAGS;
    for my $key (keys %$tags) {
        die "unknown_metadata_field\n" unless $allowed{$key};
        die "invalid_metadata_field\n" unless ref($tags->{$key}) eq 'ARRAY';
        die "invalid_metadata_field\n" if grep { !OutdoorBackup::MediaDate::JSON::string($_) } @{$tags->{$key}};
    }
    my $result = { version => 1, kind => $kind, dates => [], umid => undef, warnings => [] };
    if ($tags->{Error} || $tags->{Warning}) {
        push @{$result->{warnings}}, 'metadata_parse_warning';
        return $result;
    }
    _photo($result, $tags) if $kind eq 'photo';
    _sony($result, $tags) if $kind eq 'video' || $kind eq 'xml';
    _dji($result, $tags) if $kind eq 'video';
    validate($result);
    return $result;
}
sub _candidate {
    my ($result, $field, $value, $priority, $semantics, $profile) = @_;
    return if grep {$_ eq 'metadata_candidate_limit'} @{$result->{warnings}};
    if (@{$result->{dates}} >= 32) {
        $result->{dates} = [];
        push @{$result->{warnings}}, 'metadata_candidate_limit';
        return;
    }
    if (length($value) > 256) {
        push @{$result->{warnings}}, 'metadata_parse_warning'
            unless grep {$_ eq 'metadata_parse_warning'} @{$result->{warnings}};
        return;
    }
    push @{$result->{dates}}, { field => $field, value => $value, priority => $priority,
        semantics => $semantics, profile => $profile };
}
sub _photo {
    my ($result, $tags) = @_;
    my $sub = $tags->{SubSecTimeOriginal} || [];
    my $zone = $tags->{OffsetTimeOriginal} || [];
    if (@$sub > 1 || @$zone > 1) {
        push @{$result->{warnings}}, 'ambiguous_date_semantics';
        return;
    }
    for my $base (@{$tags->{DateTimeOriginal} || []}) {
        my $value = $base;
        $value .= '.' . $sub->[0] if @$sub;
        $value .= $zone->[0] if @$zone;
        _candidate($result, 'exif_capture', $value, 10, 'local', 'exif-local-v1');
    }
}
sub _sony {
    my ($result, $tags) = @_;
    my @umids = (@{$tags->{TargetMaterialUmidRef} || []}, @{$tags->{NonRealTimeMetaTargetMaterialUmidRef} || []});
    my %umids = map { $_ => 1 } grep { /\A[0-9a-fA-F]{64}(?:[0-9a-fA-F]{64})?\z/ } @umids;
    if (keys(%umids) == 1) { ($result->{umid}) = keys %umids }
    elsif (keys(%umids) > 1) { push @{$result->{warnings}}, 'ambiguous_recording_identity' }
    for my $name (qw(CreationDateValue NonRealTimeMetaCreationDateValue)) {
        for my $value (@{$tags->{$name} || []}) {
            # Only explicit offset semantics are evidenced for Sony XML.
            _candidate($result, 'sony_xml_capture', $value, 10, 'offset', 'sony-xml-offset-v1');
        }
    }
    # No Sony QuickTime UTC fallback: the approved evidence does not establish it.
}
sub _dji {
    my ($result, $tags) = @_;
    my $encoders = $tags->{Encoder} || [];
    if (@$encoders != 1 || $encoders->[0] ne 'DJI OsmoAction5 Pro') {
        push @{$result->{warnings}}, 'unverified_time_profile' unless @{$result->{dates}};
        return;
    }
    for my $value (@{$tags->{CreateDate} || []}) {
        _candidate($result, 'dji_oa5_capture', $value, 30, 'utc', 'dji-osmoaction5-pro-utc-v1');
    }
}

# Contract for extracted per-file metadata (including test doubles).
sub validate {
    my ($meta) = @_;
    OutdoorBackup::MediaDate::JSON::exact($meta, qw(version kind dates umid warnings));
    die "invalid_metadata_schema\n" unless OutdoorBackup::MediaDate::JSON::integer($meta->{version}) && $meta->{version} == 1
        && OutdoorBackup::MediaDate::JSON::string($meta->{kind}) && $meta->{kind} =~ /\A(?:photo|video|xml|sidecar|other)\z/
        && ref($meta->{dates}) eq 'ARRAY' && ref($meta->{warnings}) eq 'ARRAY' && @{$meta->{dates}} <= 32;
    die "invalid_umid\n" if defined($meta->{umid}) && (!OutdoorBackup::MediaDate::JSON::string($meta->{umid})
        || $meta->{umid} !~ /\A[0-9a-fA-F]{64}(?:[0-9a-fA-F]{64})?\z/);
    my %warnings = map {$_=>1} qw(xml_too_large metadata_parse_failed metadata_parse_warning metadata_candidate_limit
        ambiguous_date_semantics ambiguous_recording_identity unverified_time_profile);
    die "invalid_metadata_warning\n" if grep { !OutdoorBackup::MediaDate::JSON::string($_) || !$warnings{$_} } @{$meta->{warnings}};
    for my $date (@{$meta->{dates}}) {
        OutdoorBackup::MediaDate::JSON::exact($date, qw(field value priority semantics profile));
        _validate_date($date);
    }
    return $meta;
}

# A normalized field fixes its real semantics/profile/priority; doubles cannot
# manufacture new device profiles or promote a fallback into a peer authority.
sub _validate_date {
    my ($date) = @_;
    my %contract = (
        exif_capture => ['local', 'exif-local-v1', 10],
        sony_xml_capture => ['offset', 'sony-xml-offset-v1', 10],
        dji_oa5_capture => ['utc', 'dji-osmoaction5-pro-utc-v1', 30],
    );
    for my $key (qw(field value semantics profile)) {
        die "invalid_metadata_date\n" unless OutdoorBackup::MediaDate::JSON::string($date->{$key}) && length($date->{$key}) <= 256;
    }
    my $expected = $contract{$date->{field}};
    die "invalid_metadata_date\n" unless $expected && OutdoorBackup::MediaDate::JSON::integer($date->{priority})
        && $date->{semantics} eq $expected->[0] && $date->{profile} eq $expected->[1] && $date->{priority} == $expected->[2];
}
1;
