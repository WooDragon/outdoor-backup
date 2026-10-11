package OutdoorBackup::MediaDate::Namespace;
use strict;
use warnings;
use OutdoorBackup::MediaDate::Path ();
use OutdoorBackup::MediaDate::Date ();

# Read directory names without line splitting; unexpected component types
# cannot be traversed safely, so fail closed rather than claim emptiness.
sub _children {
    my ($path) = @_;
    my @st = lstat($path);
    die "namespace_stat_failed\n" if !@st && !$!{ENOENT};
    return () unless @st;
    die "namespace_component_conflict\n" if -l _ || !-d _;
    opendir(my $dh, $path) or die "namespace_read_failed\n";
    my @names = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh) or die "namespace_close_failed\n";
    return @names;
}
# Check intermediate type without inspecting or dereferencing its contents.
sub _directory {
    my ($path) = @_;
    my @st = lstat($path);
    die "namespace_stat_failed\n" if !@st && !$!{ENOENT};
    return unless @st;
    die "namespace_component_conflict\n" if -l _ || !-d _;
}
sub _exists {
    my ($path) = @_;
    my @st = lstat($path);
    die "namespace_stat_failed\n" if !@st && !$!{ENOENT};
    return !!@st;
}
sub _occupied {
    my ($root, $source) = @_;
    _directory($root);
    _directory("$root/Undated");
    return 1 if _exists("$root/Undated/$source");
    for my $year (_children($root)) {
        next unless $year =~ /\A\d{4}\z/;
        for my $day (_children("$root/$year")) {
            next unless OutdoorBackup::MediaDate::Date::valid_bucket("$year/$day");
            _directory("$root/$year/$day");
            return 1 if _exists("$root/$year/$day/$source");
        }
    }
    return 0;
}

# Namespace occupancy is purely path/type evidence. An empty directory itself
# counts; so do partial, symlink and special leaves. No hash/completion inference.
sub empty {
    my ($library, $source) = @_;
    OutdoorBackup::MediaDate::Path::absolute($library);
    OutdoorBackup::MediaDate::Path::uuid($source);
    # Every component joined to a filesystem byte root must also be bytes;
    # a decoded ASCII UUID otherwise upgrades the UTF-8 root bytes to text.
    $source = OutdoorBackup::MediaDate::Path::bytes($source);
    my $root = OutdoorBackup::MediaDate::Path::bytes($library);
    die "library_root_unavailable\n" unless -d $root;
    return 0 if _occupied($root, $source);
    _directory("$root/.outdoor-backup");
    my $replaced = "$root/.outdoor-backup/replaced";
    for my $job (_children($replaced)) {
        die "invalid_replaced_job\n" unless $job =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;
        return 0 if _occupied("$replaced/$job", $source);
    }
    return 1;
}
1;
