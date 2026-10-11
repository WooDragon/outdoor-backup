#!/usr/bin/env perl
# Synthetic metadata/mountinfo seam, but the actual CLI and schemas are executed.
use strict;
use warnings;
BEGIN { $INC{'Image/ExifTool.pm'} = __FILE__; package Image::ExifTool;
    our $VERSION = 'synthetic'; sub new { bless {}, shift } sub Options { 1 }
}
use lib $ENV{LIBRARY_TEST_LIB};
use OutdoorBackup::MediaDate::Planner ();
{ package SyntheticExtractor; sub extract { return {version=>1, kind=>'other', dates=>[], umid=>undef, warnings=>[]} } }
my $real_plan = \&OutdoorBackup::MediaDate::Planner::plan;
{
    no warnings 'redefine';
    *OutdoorBackup::MediaDate::Planner::plan = sub {
        return $real_plan->($_[0], extractor=>bless({},'SyntheticExtractor'),
            mountinfo=>"1 0 0:1 / / rw - tmpfs tmpfs rw\n");
    };
}
my $cli = "$ENV{LIBRARY_TEST_LIB}/../scripts/media-date-plan.pl";
my $loaded = do $cli;
die $@ if $@;
die "synthetic_cli_load_failed: $!\n" unless defined $loaded;
