#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use OutdoorBackup::MediaDate::JSON ();
use OutdoorBackup::MediaDate::Routes ();
use OutdoorBackup::MediaDate::Namespace ();
use OutdoorBackup::MediaDate::Planner ();
use OutdoorBackup::MediaDate::Path ();
use Image::ExifTool ();
use Digest::SHA ();
use Time::Local ();

# Only these exact controlled exceptions may become public machine codes.
# OS diagnostics, metadata/provider exceptions and arbitrary payloads stay private.
my %public_errors = map { ("$_\n" => $_) } qw(
    source_slot_reused reclassification_required target_leaf_collision
    target_prefix_collision target_component_conflict target_leaf_type_conflict
    foreign_target namespace_occupied namespace_component_conflict
    invalid_relative_path invalid_path_component reserved_partial_component
    invalid_absolute_path invalid_uuid unknown_request_version
    unknown_library_version unknown_library_profile invalid_archive_offset
    unknown_routes_version routes_identity_mismatch invalid_routes_entries
    missing_group_anchor invalid_date_bucket invalid_date_reason
    invalid_route_target invalid_group_anchor invalid_identity_version
    invalid_identity_signatures invalid_identity_type invalid_identity_digest
    invalid_metadata_schema invalid_metadata_field unknown_metadata_field
    invalid_metadata_warning invalid_metadata_date invalid_umid
    invalid_object unknown_or_missing_key json_duplicate_key json_trailing_data
    json_invalid_string json_invalid_unicode json_invalid_value json_depth_limit
    json_missing_colon json_missing_comma json_not_regular routes_size_limit
    source_submount source_changed source_device_changed source_count_limit
);

# Read-only commands return canonical success or bounded error JSON + nonzero.
# No partial success, shared publication, or public stderr/metadata.
sub run {
    my ($command, @args) = @_;
    die "usage: media-date-plan.pl probe|validate-library|validate-routes|namespace-empty|plan\n" unless defined $command;
    if ($command eq 'probe' && !@args) {
        my $codec = OutdoorBackup::MediaDate::JSON::decode_json('{"version":1}');
        die "digest_capability_failed\n" unless Digest::SHA::sha256_hex('synthetic') =~ /\A[0-9a-f]{64}\z/;
        OutdoorBackup::MediaDate::Extractor->new;
        return { version => 1, parser_profile => 'media-date-v1',
            modules => { 'Image::ExifTool' => "$Image::ExifTool::VERSION", 'JSON::PP' => "$JSON::PP::VERSION",
                'Digest::SHA' => "$Digest::SHA::VERSION", 'Time::Local' => "$Time::Local::VERSION" },
            limits => { files => 50000, routes_bytes => 67108864, xml_bytes => 8388608 },
            metadata_profile => 'fast-whitelist-v1', mountinfo_required => JSON::PP::true };
    }
    if ($command eq 'validate-library' && @args == 1) {
        return OutdoorBackup::MediaDate::Routes::library(OutdoorBackup::MediaDate::JSON::read_json(OutdoorBackup::MediaDate::Path::bytes($args[0])));
    }
    if ($command eq 'validate-routes' && @args == 3) {
        return OutdoorBackup::MediaDate::Routes::validate(OutdoorBackup::MediaDate::JSON::read_json(OutdoorBackup::MediaDate::Path::bytes($args[0])), $args[1], $args[2]);
    }
    if ($command eq 'namespace-empty' && @args == 2) {
        die "namespace_occupied\n" unless OutdoorBackup::MediaDate::Namespace::empty(@args);
        return { version => 1, source_id => $args[1], empty => JSON::PP::true };
    }
    if ($command eq 'plan' && @args == 1) {
        return OutdoorBackup::MediaDate::Planner::plan(OutdoorBackup::MediaDate::JSON::read_json(OutdoorBackup::MediaDate::Path::bytes($args[0]), 1024 * 1024));
    }
    die "invalid_command_arguments\n";
}
# @ARGV is raw filesystem bytes. Decode exactly once here; JSON request fields
# are already text and must not pass through this CLI conversion again.
my $result = eval { run(map { OutdoorBackup::MediaDate::Path::text($_) } @ARGV) };
if ($@) {
    my $diagnostic = $@;
    print STDERR $diagnostic;
    print OutdoorBackup::MediaDate::JSON::encode_json({ version => 1,
        error => $public_errors{$diagnostic} // 'tool_failed' }), "\n";
    exit 1;
}
print OutdoorBackup::MediaDate::JSON::encode_json($result), "\n" or die "stdout_write_failed: $!\n";
