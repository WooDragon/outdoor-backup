package OutdoorBackup::MediaDate::Scan;
use strict;
use warnings;
use Cwd qw(abs_path);
use OutdoorBackup::MediaDate::Path ();

our $MAX_FILES = 50_000;

# Fixed basename rules match backup-transfer.sh's actual six --exclude argv.
# CONFIG_FILE is manager's FieldBackup.conf contract, not dead EXCLUDE_PATTERNS.
sub excluded {
    my ($name) = @_;
    return $name eq 'FieldBackup.conf' || $name =~ /\A\.Trash/ || $name =~ /\A\.Spotlight/
        || $name eq '.fseventsd' || $name eq 'System Volume Information' || $name eq '$RECYCLE.BIN';
}

# Read our own Linux namespace. No stat-dev fallback (bind mounts share dev).
sub mountinfo {
    open(my $fh, '<:raw', '/proc/self/mountinfo') or die "mountinfo_unavailable\n";
    my $data = '';
    while (my $line = <$fh>) {
        $data .= $line;
        die "mountinfo_size_limit\n" if length($data) > 8 * 1024 * 1024;
    }
    die "mountinfo_read_failed\n" unless eof($fh);
    close($fh) or die "mountinfo_close_failed\n";
    return $data;
}

# Parse real mountinfo grammar; fixture injection is module-only, never CLI.
# Returns byte paths, respecting kernel's octal escaping (including newline).
sub mounts {
    my ($data) = @_;
    die "mountinfo_empty\n" unless length($data);
    my @mounts;
    for my $line (split /\n/, $data) {
        my @fields = split / /, $line;
        my ($sep) = grep { $fields[$_] eq '-' } 6 .. $#fields;
        die "mountinfo_invalid\n" unless defined($sep) && @fields == $sep + 4
            && $fields[0] =~ /\A\d+\z/ && $fields[1] =~ /\A\d+\z/ && $fields[2] =~ /\A\d+:\d+\z/;
        my $path = $fields[4];
        die "mountinfo_invalid\n" unless $path =~ m{\A/} && $path !~ /\\(?!0(?:40|11|12)|134)/;
        $path =~ s/\\(040|011|012|134)/chr(oct($1))/ge;
        push @mounts, $path;
    }
    return \@mounts;
}
sub check_mounts {
    my ($root, $data) = @_;
    my $prefix = $root eq '/' ? '/' : "$root/";
    for my $mount (@{mounts($data)}) {
        die "source_submount\n" if $mount ne $root && index($mount, $prefix) == 0;
    }
}

# Scan accepted regular files without following links. Returns bounded per-file
# metadata and excluded tree-root count; never reads content to infer completion.
sub scan {
    my ($source, %options) = @_;
    my $root = abs_path(OutdoorBackup::MediaDate::Path::bytes($source));
    die "source_root_unavailable\n" unless defined($root) && -d $root;
    my $data = exists($options{mountinfo}) ? $options{mountinfo} : mountinfo();
    check_mounts($root, $data);
    my @root_stat = stat($root);
    my @directories = [''];
    my (%files, $excluded, $unsupported);
    $excluded = $unsupported = 0;
    while (@directories) {
        my ($relative) = @{pop @directories};
        opendir(my $dh, $root . (length($relative) ? "/$relative" : '')) or die "source_read_failed\n";
        my @names = readdir($dh);
        closedir($dh) or die "source_close_failed\n";
        for my $name (@names) {
            next if $name eq '.' || $name eq '..';
            my $rel = length($relative) ? "$relative/$name" : $name;
            my $text = OutdoorBackup::MediaDate::Path::text($rel);
            OutdoorBackup::MediaDate::Path::relative($text);
            if (excluded($name)) { ++$excluded; next }
            my @st = lstat("$root/$rel");
            die "source_stat_failed\n" unless @st;
            die "source_device_changed\n" if $st[0] != $root_stat[0];
            if (-l _ || (!-f _ && !-d _)) { ++$unsupported; next }
            if (-d _) { push @directories, [$rel]; next }
            $files{$text} = { path => OutdoorBackup::MediaDate::Path::text("$root/$rel"),
                dev => $st[0], ino => $st[1], size => $st[7], mtime => $st[9] };
            die "source_count_limit\n" if keys(%files) > $MAX_FILES;
        }
    }
    die "unsupported_source_items:$unsupported\n" if $unsupported;
    return { files => \%files, excluded_total => $excluded, root => $root };
}

# Recheck before making a controlled symlink, without hashing any media bytes.
sub recheck {
    my ($file) = @_;
    my @st = lstat(OutdoorBackup::MediaDate::Path::bytes($file->{path}));
    die "source_changed\n" unless @st && !-l _ && -f _ && $st[0] == $file->{dev}
        && $st[1] == $file->{ino} && $st[7] == $file->{size} && $st[9] == $file->{mtime};
}
1;
