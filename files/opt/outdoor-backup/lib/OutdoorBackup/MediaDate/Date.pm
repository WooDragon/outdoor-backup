package OutdoorBackup::MediaDate::Date;
use strict;
use warnings;
use Time::Local qw(timegm_modern);
use OutdoorBackup::MediaDate::JSON ();

# Parse a trusted candidate to an interval and explicit comparison coordinate.
# Input schema is validated by Extractor; malformed date values return undef.
sub parse {
    my ($candidate, $archive_offset) = @_;
    my $value = $candidate->{value};
    return unless $value =~ /\A(\d{4})[:-](\d\d)[:-](\d\d)[T ](\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)?\z/;
    my ($year, $month, $day, $hour, $minute, $second, $subsec, $offset) = ($1,$2,$3,$4,$5,$6,$7,$8);
    return if $year < 1 || $month < 1 || $month > 12 || $hour > 23 || $minute > 59 || $second > 59;
    my $epoch = eval { timegm_modern($second, $minute, $hour, $day, $month - 1, $year) };
    return if $@;
    my @check = gmtime($epoch);
    return unless $check[3] == $day && $check[4] + 1 == $month && $check[5] + 1900 == $year;
    my $zone = 0;
    if (defined $offset && $offset ne 'Z') {
        my ($sign, $hours, $minutes) = $offset =~ /([+-])(\d\d):(\d\d)/;
        return if $minutes > 59 || $hours > 14 || ($hours == 14 && $minutes != 0);
        $zone = ($hours * 60 + $minutes) * ($sign eq '-' ? -1 : 1);
    }
    my $absolute = defined($offset) || $candidate->{semantics} eq 'utc';
    return if !$absolute && $candidate->{semantics} ne 'local';
    # Keep integer seconds and nanosecond ticks separate: floating Unix time
    # rounds 23:59:59.999999999 into the next day on contemporary dates.
    my $start = $epoch - ($absolute ? $zone * 60 : 0);
    my $tick = defined($subsec) ? 0 + ($subsec . ('0' x (9 - length($subsec)))) : 0;
    my $width = defined($subsec) ? 10 ** (9 - length($subsec)) : 1_000_000_000;
    my $end_tick = $tick + $width;
    my $end = $start + int($end_tick / 1_000_000_000);
    $end_tick %= 1_000_000_000;
    my $coordinate = defined($offset) ? $zone : ($absolute ? $archive_offset : 0);
    my $date = bucket($start + ($absolute ? $coordinate * 60 : 0));
    return { bucket => $date, start => $start, tick => $tick, end => $end, end_tick => $end_tick,
             absolute => $absolute ? 1 : 0, coordinate => $coordinate,
             profile => $candidate->{profile}, field => $candidate->{field} };
}

# Convert a civil/UTC second coordinate to the fixed YYYY/YYYYMMDD layout.
sub bucket {
    my ($seconds) = @_;
    my @date = gmtime($seconds);
    return sprintf('%04d/%04d%02d%02d', $date[5]+1900, $date[5]+1900, $date[4]+1, $date[3]);
}
sub valid_bucket {
    my ($value) = @_;
    return 0 unless OutdoorBackup::MediaDate::JSON::string($value);
    return 1 if $value eq 'Undated';
    return 0 unless $value =~ /\A(\d{4})\/\1(\d\d)(\d\d)\z/;
    my $candidate = { value => "$1-$2-$3" . 'T00:00:00', semantics => 'local', profile => 'calendar', field => 'calendar' };
    return !!parse($candidate, 0);
}

# True peer comparisons only: fallbacks are removed before this stage.
# Compare in primary's coordinate; overlapping precision intervals are equal.
sub compare {
    my ($primary, $peer) = @_;
    if ($primary->{absolute} && $peer->{absolute}) {
        my $primary_before_end = $primary->{start} < $peer->{end}
            || ($primary->{start} == $peer->{end} && $primary->{tick} < $peer->{end_tick});
        my $peer_before_end = $peer->{start} < $primary->{end}
            || ($peer->{start} == $primary->{end} && $peer->{tick} < $primary->{end_tick});
        return '' if $primary_before_end && $peer_before_end;
        my $peer_date = bucket($peer->{start} + $primary->{coordinate} * 60);
        return $peer_date eq $primary->{bucket} ? '' : 'conflicting_capture_date';
    }
    if (!$primary->{absolute} && !$peer->{absolute} && $primary->{profile} eq $peer->{profile}) {
        return $peer->{bucket} eq $primary->{bucket} ? '' : 'conflicting_capture_date';
    }
    return 'ambiguous_date_semantics';
}

# Highest legal priority wins; invalid higher fields permit lower fallback.
# Returns decision and chosen primary interval for group peer comparisons.
sub choose {
    my ($dates, $offset) = @_;
    my @valid;
    for my $candidate (@$dates) {
        my $parsed = parse($candidate, $offset);
        push @valid, [$candidate->{priority}, $parsed] if $parsed;
    }
    return { bucket => 'Undated', reason => 'no_capture_date', primary => undef } unless @valid;
    @valid = sort { $a->[0] <=> $b->[0] } @valid;
    my $primary = $valid[0][1];
    for my $peer (@valid) {
        next unless $peer->[0] == $valid[0][0];
        my $reason = compare($primary, $peer->[1]);
        return { bucket => 'Undated', reason => $reason, primary => $primary } if $reason;
    }
    return { bucket => $primary->{bucket}, reason => $primary->{field}, primary => $primary };
}
1;
