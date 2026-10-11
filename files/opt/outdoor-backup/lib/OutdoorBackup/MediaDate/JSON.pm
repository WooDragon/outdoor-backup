package OutdoorBackup::MediaDate::JSON;
use strict;
use warnings;
use JSON::PP ();
use Encode qw(decode FB_CROAK);
use B ();
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);

our $MAX_ROUTES = 64 * 1024 * 1024;

# Return canonical UTF-8 bytes; callers never interpolate JSON into shell.
sub encode_json { JSON::PP->new->canonical->utf8->encode($_[0]) }

# JSON scalar types must be checked before string operations add Perl flags.
sub integer {
    my ($value) = @_;
    return 0 if !defined($value) || ref($value);
    my $flags = B::svref_2object(\$value)->FLAGS;
    return ($flags & B::SVp_IOK()) && !($flags & B::SVp_POK());
}
sub string {
    my ($value) = @_;
    return 0 if !defined($value) || ref($value);
    return !!(B::svref_2object(\$value)->FLAGS & B::SVp_POK());
}

# Require exactly these object keys (not an array, scalar or bool).
sub exact {
    my ($object, @keys) = @_;
    die "invalid_object\n" unless ref($object) eq 'HASH';
    die "unknown_or_missing_key\n" unless join("\0", sort keys %$object) eq join("\0", sort @keys);
}

# Decode strict UTF-8 JSON with duplicate detection at every nesting level.
# JSON::PP alone accepts duplicate keys. The structural walk precedes decode.
sub decode_json {
    my ($bytes) = @_;
    my $text = decode('UTF-8', $bytes, FB_CROAK);
    my $parser = bless { text => $text, at => 0, depth => 0 }, __PACKAGE__;
    $parser->_value;
    $parser->_space;
    die "json_trailing_data\n" unless $parser->{at} == length($text);
    return JSON::PP->new->decode($text);
}
sub _space {
    my ($self) = @_;
    pos($self->{text}) = $self->{at};
    $self->{text} =~ /\G[ \t\r\n]*/gc;
    $self->{at} = pos($self->{text});
}
sub _take {
    my ($self, $char) = @_;
    $self->_space;
    return 0 unless substr($self->{text}, $self->{at}, 1) eq $char;
    ++$self->{at};
    return 1;
}
sub _string {
    my ($self) = @_;
    $self->_space;
    pos($self->{text}) = $self->{at};
    $self->{text} =~ /\G("(?:[^"\\\x00-\x1f]|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*")/gc
        or die "json_invalid_string\n";
    my $token = $1;
    $self->{at} = pos($self->{text});
    my $value = JSON::PP->new->allow_nonref->decode($token);
    die "json_invalid_unicode\n" if $value =~ /[\x{d800}-\x{dfff}]/;
    return $value;
}
sub _object {
    my ($self) = @_;
    my %seen;
    return if $self->_take('}');
    while (1) {
        my $key = $self->_string;
        die "json_duplicate_key\n" if $seen{$key}++;
        die "json_missing_colon\n" unless $self->_take(':');
        $self->_value;
        last if $self->_take('}');
        die "json_missing_comma\n" unless $self->_take(',');
    }
}
sub _array {
    my ($self) = @_;
    return if $self->_take(']');
    while (1) {
        $self->_value;
        last if $self->_take(']');
        die "json_missing_comma\n" unless $self->_take(',');
    }
}
sub _value {
    my ($self) = @_;
    die "json_depth_limit\n" if ++$self->{depth} > 64;
    $self->_space;
    if ($self->_take('{')) { $self->_object }
    elsif ($self->_take('[')) { $self->_array }
    elsif (substr($self->{text}, $self->{at}, 1) eq '"') { $self->_string }
    else {
        pos($self->{text}) = $self->{at};
        $self->{text} =~ /\G(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc
            or die "json_invalid_value\n";
        $self->{at} = pos($self->{text});
    }
    --$self->{depth};
}

# Bounded regular-file read without following a leaf symlink. Returns an object.
sub read_json {
    my ($path, $limit) = @_;
    $limit //= $MAX_ROUTES;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die "json_open_failed: $!\n";
    die "json_not_regular\n" unless -f $fh;
    my $bytes = '';
    while (1) {
        my $read = sysread($fh, my $chunk, 65536);
        die "json_read_failed: $!\n" unless defined $read;
        last unless $read;
        $bytes .= $chunk;
        die "routes_size_limit\n" if length($bytes) > $limit;
    }
    close($fh) or die "json_close_failed: $!\n";
    return decode_json($bytes);
}

# Write only a new private output; no overwrites, publication, or shared state.
sub write_json {
    my ($path, $object) = @_;
    my $bytes = encode_json($object);
    die "routes_size_limit\n" if length($bytes) > $MAX_ROUTES;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        or die "json_output_open_failed: $!\n";
    print {$fh} $bytes, "\n" or die "json_output_write_failed: $!\n";
    close($fh) or die "json_output_close_failed: $!\n";
}
1;
