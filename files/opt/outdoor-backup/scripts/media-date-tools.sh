#!/bin/sh
# Source-only private, fixed-argv validation/stat tools. No media copying/hashing.

# Materialize a fixed owner-private script (never source output or accept code).
# Args: none. Returns 0/1; all script invocations use the existing runner.
media_date_write_tools() {
    cat > "$MEDIA_DATE_WORK/tools.pl" <<'PERL'
use strict;
use warnings;
use utf8;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
use File::Find ();
use Cwd qw(abs_path);
use OutdoorBackup::MediaDate::JSON ();
use OutdoorBackup::MediaDate::Routes ();
use OutdoorBackup::MediaDate::Path ();
my ($mode, @args) = @ARGV;
sub read_object { OutdoorBackup::MediaDate::JSON::read_json($_[0]) }
sub exact { OutdoorBackup::MediaDate::JSON::exact(@_) }
sub integer { OutdoorBackup::MediaDate::JSON::integer($_[0]) }
sub string { OutdoorBackup::MediaDate::JSON::string($_[0]) }
sub nonnegative { die "invalid_count\n" unless integer($_[0]) && $_[0] >= 0 }
sub probe {
    my ($object) = @_;
    exact($object, qw(version parser_profile modules limits metadata_profile mountinfo_required));
    die "invalid_probe\n" unless integer($object->{version}) && $object->{version} == 1
        && string($object->{parser_profile}) && $object->{parser_profile} eq 'media-date-v1'
        && string($object->{metadata_profile}) && $object->{metadata_profile} eq 'fast-whitelist-v1'
        && JSON::PP::is_bool($object->{mountinfo_required}) && $object->{mountinfo_required};
    exact($object->{modules}, qw(Image::ExifTool JSON::PP Digest::SHA Time::Local));
    for my $version (values %{$object->{modules}}) {
        die "invalid_module_version\n" unless string($version) && length($version) && length($version) < 128;
    }
    exact($object->{limits}, qw(files routes_bytes xml_bytes));
    my %limits = (files=>50000, routes_bytes=>67108864, xml_bytes=>8388608);
    for my $key (keys %limits) {
        die "invalid_probe_limit\n" unless integer($object->{limits}{$key}) && $object->{limits}{$key} == $limits{$key};
    }
}
sub identity {
    my ($file, $sd, $fs) = @_;
    my $object = read_object($file);
    exact($object, qw(version sd_uuid fs_uuid));
    die "invalid_identity\n" unless integer($object->{version}) && $object->{version} == 1
        && string($object->{sd_uuid}) && $object->{sd_uuid} eq $sd
        && string($object->{fs_uuid}) && $object->{fs_uuid} eq $fs;
}
sub result {
    my ($file, $work, $library, $source, $history_file, $source_root) = @_;
    my $object = read_object($file);
    exact($object, qw(version parser_profile library_id source_id files_total source_bytes_total routes_total excluded_total undated_total warnings outputs));
    die "invalid_result\n" unless integer($object->{version}) && $object->{version} == 1
        && string($object->{parser_profile}) && $object->{parser_profile} eq 'media-date-v1'
        && string($object->{library_id}) && $object->{library_id} eq $library
        && string($object->{source_id}) && $object->{source_id} eq $source;
    nonnegative($object->{$_}) for qw(files_total source_bytes_total routes_total excluded_total undated_total);
    die "invalid_result_count\n" if $object->{files_total} > 50000 || $object->{undated_total} > $object->{files_total}
        || $object->{routes_total} < $object->{files_total};
    exact($object->{outputs}, qw(view routes result));
    for my $key (qw(view routes result)) {
        my %expected = (view=>'view', routes=>'routes.json', result=>'result.json');
        die "invalid_outputs\n" unless string($object->{outputs}{$key}) && $object->{outputs}{$key} eq $expected{$key};
    }
    die "invalid_warnings\n" unless ref($object->{warnings}) eq 'ARRAY';
    my %warning_codes = map { $_=>1 } qw(no_capture_date exif_capture sony_xml_capture dji_oa5_capture conflicting_capture_date ambiguous_date_semantics metadata_parse_failed xml_too_large metadata_parse_warning metadata_candidate_limit ambiguous_recording_identity unverified_time_profile ambiguous_pairing primary_not_present);
    for my $warning (@{$object->{warnings}}) {
        exact($warning, qw(source_relpath code));
        OutdoorBackup::MediaDate::Path::relative($warning->{source_relpath});
        die "invalid_warning_code\n" unless string($warning->{code}) && $warning_codes{$warning->{code}};
    }
    my $candidate = OutdoorBackup::MediaDate::Routes::validate(read_object("$work/routes.json"), $library, $source);
    my $history = OutdoorBackup::MediaDate::Routes::validate(read_object($history_file), $library, $source);
    die "invalid_routes_count\n" unless $object->{routes_total} == keys %{$candidate->{entries}};
    for my $path (keys %{$history->{entries}}) {
        my $old = $history->{entries}{$path};
        my $new = $candidate->{entries}{$path} or die "history_dropped\n";
        die "history_moved\n" unless $old->{target_relpath} eq $new->{target_relpath} && $old->{bucket} eq $new->{bucket};
    }
    my $disk = read_object("$work/result.json");
    die "result_disagrees\n" unless OutdoorBackup::MediaDate::JSON::encode_json($disk) eq OutdoorBackup::MediaDate::JSON::encode_json($object);
    die "view_unavailable\n" unless -d "$work/view" && !-l "$work/view";
    result_view($object, $candidate, "$work/view", $source_root);
}
# Cross-check counts against the current controlled view, never media contents.
sub result_view {
    my ($result, $routes, $root, $source_root) = @_;
    my $source = abs_path(OutdoorBackup::MediaDate::Path::bytes($source_root));
    die "source_root_missing\n" unless defined($source);
    my %by_target = map { $routes->{entries}{$_}{target_relpath} => $_ } keys %{$routes->{entries}};
    my ($files, $bytes, $undated, %current) = (0,0,0);
    local $SIG{__WARN__} = sub { die "view_read_failed\n" };
    File::Find::find({no_chdir=>1, wanted=>sub {
        my $path = $File::Find::name;
        my @st = lstat($path); die "view_stat_failed\n" unless @st;
        return if -d _ && !-l _;
        die "view_leaf_not_link\n" unless -l _;
        my $target = OutdoorBackup::MediaDate::Path::text(substr($path, length($root)+1));
        my $relative = $by_target{$target}; die "view_unregistered\n" unless defined($relative);
        my $expected = "$source/" . OutdoorBackup::MediaDate::Path::bytes($relative);
        my $link = readlink($path); die "view_foreign_link\n" unless defined($link) && $link eq $expected;
        @st = lstat($expected); die "view_source_not_regular\n" unless @st && -f _ && !-l _;
        ++$files; $bytes += $st[7]; ++$undated if $routes->{entries}{$relative}{bucket} eq 'Undated';
        $current{$relative}=1;
    }}, $root);
    die "view_counts_disagree\n" unless $files == $result->{files_total} && $bytes == $result->{source_bytes_total} && $undated == $result->{undated_total};
    my %seen;
    for my $warning (@{$result->{warnings}}) {
        die "warning_not_current\n" unless $current{$warning->{source_relpath}};
        die "duplicate_warning\n" if $seen{"$warning->{source_relpath}\0$warning->{code}"}++;
    }
}
# Four distinct UTF-8 byte names must remain distinct inodes AND contents.
# Rename uses Perl's same-filesystem syscall, never mv's copy fallback.
sub filesystem {
    my ($directory) = @_;
    my @root = stat($directory); die "probe_root_missing\n" unless @root;
    my @names = ('Case', 'case', "\x{e9}", "e\x{301}");
    my %inodes;
    for my $index (0..$#names) {
        my $file = "$directory/" . OutdoorBackup::MediaDate::Path::bytes($names[$index]);
        sysopen(my $fh, $file, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600) or die "probe_create_failed\n";
        print {$fh} "$index\n" or die "probe_write_failed\n";
        close($fh) or die "probe_close_failed\n";
        my @st = lstat($file);
        die "probe_inode_failed\n" unless @st && -f _ && $st[0] == $root[0] && !$inodes{$st[1]}++;
    }
    for my $index (0..$#names) {
        my $file = "$directory/" . OutdoorBackup::MediaDate::Path::bytes($names[$index]);
        open(my $fh, '<:raw', $file) or die "probe_read_failed\n";
        local $/; my $content = <$fh>;
        close($fh) or die "probe_close_failed\n";
        die "probe_content_failed\n" unless defined($content) && $content eq "$index\n";
    }
    my $old = "$directory/Case"; my @before = lstat($old);
    rename($old, "$directory/renamed") or die "probe_rename_failed\n";
    my @after = lstat("$directory/renamed");
    die "probe_rename_result_failed\n" unless @after && $before[0] == $after[0] && $before[1] == $after[1] && !-e $old;
}
# Stat-only risk bound over CURRENT candidate targets/partials, not a whole-library du.
sub risk {
    my ($file, $root) = @_;
    my $routes = read_object($file);
    my ($pending, $replacement) = (0,0);
    for my $entry (values %{$routes->{entries}}) {
        my $target = "$root/" . OutdoorBackup::MediaDate::Path::bytes($entry->{target_relpath});
        my @st = lstat($target);
        die "risk_stat_failed\n" if !@st && !$!{ENOENT};
        if (@st) { die "risk_target_type\n" unless -f _ && !-l _; $replacement += $st[7] }
        my ($parent, $leaf) = $target =~ m{\A(.+)/([^/]+)\z};
        my $partial_dir = "$parent/.rsync-partial";
        @st = lstat($partial_dir);
        die "risk_stat_failed\n" if !@st && !$!{ENOENT};
        die "risk_partial_type\n" if @st && (!-d _ || -l _);
        @st = lstat("$partial_dir/$leaf");
        die "risk_stat_failed\n" if !@st && !$!{ENOENT};
        if (@st) { die "risk_partial_type\n" unless -f _ && !-l _; $pending += $st[7] }
    }
    return {pending_bytes_bound=>$pending, replacement_bytes_bound=>$replacement};
}
# Replaced count preserves newline/tab/Unicode names, never dereferences symlinks.
sub counts {
    my ($root) = @_;
    die "count_root_invalid\n" unless -d $root && !-l $root;
    my $count = 0;
    local $SIG{__WARN__} = sub { die "count_directory_read_failed\n" };
    File::Find::find({no_chdir=>1, wanted=>sub {
        my @st = lstat($File::Find::name); die "count_stat_failed\n" unless @st;
        die "count_type_invalid\n" if -l _ || (!-f _ && !-d _);
        ++$count if -f _;
    }}, $root);
    return {replaced_count=>$count};
}
my $output = {};
if ($mode eq 'probe') { probe(read_object($args[0])) }
elsif ($mode eq 'identity') { identity(@args) }
elsif ($mode eq 'result') { result(@args) }
elsif ($mode eq 'filesystem') { filesystem(@args) }
elsif ($mode eq 'risk') { $output = risk(@args) }
elsif ($mode eq 'counts') { $output = counts(@args) }
elsif ($mode eq 'library') { $output = OutdoorBackup::MediaDate::Routes::library(read_object($args[0])) }
elsif ($mode eq 'routes') { $output = OutdoorBackup::MediaDate::Routes::validate(read_object($args[0]), @args[1,2]) }
elsif ($mode eq 'namespace') {
    my $object = read_object($args[0]); exact($object, qw(version source_id empty));
    die "invalid_namespace_output\n" unless integer($object->{version}) && $object->{version} == 1
        && string($object->{source_id}) && $object->{source_id} eq $args[1]
        && JSON::PP::is_bool($object->{empty}) && $object->{empty};
}
elsif ($mode eq 'canonical') { $output = read_object($args[0]) }
else { die "unknown_private_tool\n" }
print OutdoorBackup::MediaDate::JSON::encode_json($output), "\n" or die "tool_stdout_failed\n";
PERL
}

# Run one fixed private tool through runner. Args: mode and fixed data arguments.
# Returns 0/command status; stdout stays in private tools.json.
media_date_tool() {
    media_date_run "$MEDIA_DATE_WORK/tools.json" perl -I "$SCRIPT_DIR/../lib" \
        "$MEDIA_DATE_WORK/tools.pl" "$@"
}

# Probe only an owner-created FD9 child, deleting only that exact private child.
# Args: none. Returns nonzero on unsupported FS or any capability/check error.
media_date_probe_filesystem() {
    case "$TARGET_FS_TYPE" in ext4|btrfs) ;; *) media_date_fail unsupported_filesystem; return 1 ;; esac
    media_date_guard || return "$?"
    MEDIA_DATE_PROBE=$(umask 077; mktemp -d "$TARGET_FD_ROOT/.media-date-probe.XXXXXX") || return 1
    media_date_tool filesystem "$MEDIA_DATE_PROBE"
    md_probe_rc=$?
    if lock_is_owned_by_self && target_anchor_healthy; then
        rm -rf "$MEDIA_DATE_PROBE" || md_probe_rc=1
    else
        md_probe_rc=1
    fi
    MEDIA_DATE_PROBE=
    [ "$md_probe_rc" -eq 0 ] || { media_date_fail filesystem_capability_failed; return "$md_probe_rc"; }
    media_date_guard
}
