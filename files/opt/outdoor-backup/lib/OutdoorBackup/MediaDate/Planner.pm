package OutdoorBackup::MediaDate::Planner;
use strict;
use warnings;
use Cwd qw(abs_path);
use OutdoorBackup::MediaDate::JSON ();
use OutdoorBackup::MediaDate::Path ();
use OutdoorBackup::MediaDate::Routes ();
use OutdoorBackup::MediaDate::Scan ();
use OutdoorBackup::MediaDate::Extractor ();
use OutdoorBackup::MediaDate::Groups ();

# Exact versioned request; no metadata-selected output paths or arbitrary argv.
sub request {
    my ($request) = @_;
    OutdoorBackup::MediaDate::JSON::exact($request, qw(version source_root library_root source_id library route_file work_dir));
    die "unknown_request_version\n" unless OutdoorBackup::MediaDate::JSON::integer($request->{version}) && $request->{version} == 1;
    OutdoorBackup::MediaDate::Routes::library($request->{library});
    OutdoorBackup::MediaDate::Path::uuid($request->{source_id});
    OutdoorBackup::MediaDate::Path::absolute($request->{$_}) for qw(source_root library_root route_file work_dir);
    my @work = lstat(OutdoorBackup::MediaDate::Path::bytes($request->{work_dir}));
    die "work_directory_not_private\n" unless @work && !-l _ && -d _ && ($work[2] & 07777) == 0700 && $work[4] == $>;
    die "library_root_unavailable\n" unless -d OutdoorBackup::MediaDate::Path::bytes($request->{library_root});
    for my $name (qw(view routes.json result.json)) {
        my @st = lstat(OutdoorBackup::MediaDate::Path::bytes("$request->{work_dir}/$name"));
        die "work_output_exists\n" if @st;
        die "work_stat_failed\n" unless $!{ENOENT};
    }
    my $source = abs_path(OutdoorBackup::MediaDate::Path::bytes($request->{source_root}));
    die "source_root_unavailable\n" unless defined $source;
    for my $key (qw(work_dir library_root route_file)) {
        my $path = abs_path(OutdoorBackup::MediaDate::Path::bytes($request->{$key}));
        die "input_path_unavailable\n" unless defined $path;
        die "input_inside_source\n" if $path eq $source || index($path, "$source/") == 0;
    }
    return $request;
}

# Module-only injected extractor/mountinfo are for semantic and namespace
# fixtures. Public CLI always uses the real Extractor and /proc/self/mountinfo.
sub plan {
    my ($request, %options) = @_;
    request($request);
    my $library_id = $request->{library}{library_id};
    my $source_id = $request->{source_id};
    my $history = OutdoorBackup::MediaDate::Routes::validate(
        OutdoorBackup::MediaDate::JSON::read_json(OutdoorBackup::MediaDate::Path::bytes($request->{route_file})), $library_id, $source_id);
    my $scan = OutdoorBackup::MediaDate::Scan::scan($request->{source_root},
        exists($options{mountinfo}) ? (mountinfo => $options{mountinfo}) : ());
    my $extractor = $options{extractor} || OutdoorBackup::MediaDate::Extractor->new;
    my %metadata;
    for my $path (OutdoorBackup::MediaDate::Path::byte_sort(keys %{$scan->{files}})) {
        OutdoorBackup::MediaDate::Scan::recheck($scan->{files}{$path});
        $metadata{$path} = OutdoorBackup::MediaDate::Extractor::validate($extractor->extract($scan->{files}{$path}{path}));
    }
    my ($groups, $warnings) = OutdoorBackup::MediaDate::Groups::build(\%metadata, $history->{entries});
    my $candidate = _candidate($request, $groups, \%metadata, $history, $warnings);
    OutdoorBackup::MediaDate::Routes::validate($candidate, $library_id, $source_id);
    _targets($request, $candidate, $history);
    my $route_bytes = OutdoorBackup::MediaDate::JSON::encode_json($candidate);
    die "routes_size_limit\n" if length($route_bytes) + 1 > $OutdoorBackup::MediaDate::JSON::MAX_ROUTES;
    OutdoorBackup::MediaDate::Scan::check_mounts($scan->{root}, exists($options{mountinfo}) ? $options{mountinfo} : OutdoorBackup::MediaDate::Scan::mountinfo());
    _view($request, $scan, $candidate);
    my $result = _result($request, $scan, $candidate, $warnings);
    OutdoorBackup::MediaDate::JSON::write_json(OutdoorBackup::MediaDate::Path::bytes("$request->{work_dir}/routes.json"), $candidate);
    OutdoorBackup::MediaDate::JSON::write_json(OutdoorBackup::MediaDate::Path::bytes("$request->{work_dir}/result.json"), $result);
    return $result;
}
sub _candidate {
    my ($request, $groups, $metadata, $history, $warnings) = @_;
    my %entries = map { $_ => { %{$history->{entries}{$_}} } } keys %{$history->{entries}};
    for my $members (values %$groups) {
        my $decision = OutdoorBackup::MediaDate::Groups::decision($members, $metadata, $history->{entries}, $request->{library}{archive_offset_minutes});
        for my $path (@$members) {
            my $old = $history->{entries}{$path};
            my $identity = OutdoorBackup::MediaDate::Routes::identity($metadata->{$path});
            $identity = OutdoorBackup::MediaDate::Routes::merge_identity($old ? $old->{recording_identity} : undef, $identity);
            $entries{$path} = { group_anchor => $decision->{anchor}, recording_identity => $identity,
                bucket => $decision->{bucket}, date_reason => $old ? $old->{date_reason} : $decision->{reason},
                target_relpath => "$decision->{bucket}/$request->{source_id}/$path" };
            $warnings->{$path}{$decision->{reason}} = 1 if $decision->{bucket} eq 'Undated';
        }
    }
    return { version => 1, library_id => $request->{library}{library_id}, source_id => $request->{source_id}, entries => \%entries };
}
sub _targets {
    my ($request, $candidate, $history) = @_;
    for my $path (keys %{$candidate->{entries}}) {
        OutdoorBackup::MediaDate::Path::target_check($request->{library_root}, $candidate->{entries}{$path}{target_relpath}, exists($history->{entries}{$path}));
    }
}

# Make real 0700 parents and controlled symlink leaves, only after all checks.
# Partial private output on failure belongs to manager cleanup after drain.
sub _view {
    my ($request, $scan, $candidate) = @_;
    my $root = OutdoorBackup::MediaDate::Path::bytes("$request->{work_dir}/view");
    mkdir($root, 0700) or die "view_mkdir_failed: $!\n";
    my %made = ($root => 1);
    for my $path (OutdoorBackup::MediaDate::Path::byte_sort(keys %{$scan->{files}})) {
        my @parts = split '/', $candidate->{entries}{$path}{target_relpath};
        my $leaf = pop @parts;
        my $parent = $root;
        for my $part (@parts) {
            $parent .= '/' . OutdoorBackup::MediaDate::Path::bytes($part);
            next if $made{$parent};
            mkdir($parent, 0700) or die "view_parent_failed: $!\n";
            $made{$parent} = 1;
        }
        OutdoorBackup::MediaDate::Scan::recheck($scan->{files}{$path});
        symlink(OutdoorBackup::MediaDate::Path::bytes($scan->{files}{$path}{path}), "$parent/" . OutdoorBackup::MediaDate::Path::bytes($leaf))
            or die "view_symlink_failed: $!\n";
    }
}
sub _result {
    my ($request, $scan, $candidate, $warnings) = @_;
    my @warnings;
    my ($undated, $bytes) = (0, 0);
    for my $path (OutdoorBackup::MediaDate::Path::byte_sort(keys %{$scan->{files}})) {
        ++$undated if $candidate->{entries}{$path}{bucket} eq 'Undated';
        $bytes += $scan->{files}{$path}{size};
        push @warnings, map { { source_relpath => $path, code => $_ } } sort keys %{$warnings->{$path} || {}};
    }
    return { version => 1, parser_profile => 'media-date-v1', library_id => $request->{library}{library_id},
        source_id => $request->{source_id}, files_total => scalar(keys %{$scan->{files}}), source_bytes_total => $bytes,
        routes_total => scalar(keys %{$candidate->{entries}}), excluded_total => $scan->{excluded_total}, undated_total => $undated,
        warnings => \@warnings, outputs => { view => 'view', routes => 'routes.json', result => 'result.json' } };
}
1;
