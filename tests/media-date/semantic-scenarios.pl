#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../files/opt/outdoor-backup/lib";
use Test::More;
use File::Temp qw(tempdir);
use OutdoorBackup::MediaDate::Date ();
use OutdoorBackup::MediaDate::Extractor ();
use OutdoorBackup::MediaDate::Groups ();
use OutdoorBackup::MediaDate::Routes ();
use OutdoorBackup::MediaDate::Path ();
use OutdoorBackup::MediaDate::Scan ();
use OutdoorBackup::MediaDate::Planner ();
use OutdoorBackup::MediaDate::JSON ();

my $uuid = '11111111-2222-4333-8444-555555555555';
my $source = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
my $umid = '1' x 64;

# All doubles accept only actual Extractor raw tag schema, and normalize using
# delivered production code. No alternative fictional normalized interface.
sub meta { OutdoorBackup::MediaDate::Extractor::normalize(@_) }
sub candidate {
    my ($value, $semantics, $priority, $profile) = @_;
    return { value => $value, semantics => $semantics // 'offset', priority => $priority // 10,
        profile => $profile // 'sony-xml-offset-v1', field => 'sony_xml_capture' };
}
sub choose { OutdoorBackup::MediaDate::Date::choose($_[0], 480) }
sub rejects {
    my ($code, $reason, $name) = @_;
    eval { $code->() };
    like($@, qr/\Q$reason\E/, $name);
}
sub history {
    my ($path, $bucket) = @_;
    return { $path => { group_anchor => $path, recording_identity => undef, bucket => $bucket,
        date_reason => $bucket eq 'Undated' ? 'no_capture_date' : 'exif_capture', target_relpath => "$bucket/$source/$path" } };
}
sub group {
    my ($metadata, $old) = @_;
    my ($groups, $warnings) = OutdoorBackup::MediaDate::Groups::build($metadata, $old || {});
    my %decisions;
    for my $members (values %$groups) {
        my $decision = OutdoorBackup::MediaDate::Groups::decision($members, $metadata, $old || {}, 480);
        $decisions{$_} = $decision for @$members;
    }
    return (\%decisions, $warnings);
}

is(choose([candidate('2026-08-09T00:30:00+09:00')])->{bucket}, '2026/20260809', 'M03 explicit offset preserves local day');
is(choose([candidate('2026:08:08 20:30:00', 'utc')])->{bucket}, '2026/20260809', 'M05 UTC converts library offset');
is(choose([candidate('1900:01:01 00:00:00', 'local')])->{bucket}, '1900/19000101', 'M07 legitimate historical year');
is(choose([candidate('0001:01:01 00:00:00', 'local')])->{bucket}, '0001/00010101', 'M07 historical year does not use sliding window');
for my $value ('', '0000:00:00 00:00:00', '2026:02:29 00:00:00', '2024:02:30 00:00:00',
               '2026:08:08 24:00:00', '2026:08:08 00:00:60', '2026:08:08 00:00:00+14:01',
               '2026:08:08 00:00:00-15:00', '2026:08:08 00:00:00+08:60') {
    is(choose([candidate($value)])->{bucket}, 'Undated', "M07 rejects invalid $value");
}
is(choose([candidate('2024:02:29 12:00:00Z')])->{bucket}, '2024/20240229', 'M07 accepts leap day');
for my $offset ('+14:00','-14:00') {
    isnt(choose([candidate("2026-08-09T00:00:00$offset")])->{bucket}, 'Undated', 'M07 offset boundary');
}
my $photo = meta('photo', { DateTimeOriginal => ['2026:08:08 23:59:59'], SubSecTimeOriginal => ['123'], OffsetTimeOriginal => ['+09:00'] });
is(choose($photo->{dates})->{bucket}, '2026/20260808', 'M03 real EXIF scalar normalization combines subsecond/offset');
is(choose(meta('photo', { DateTimeOriginal => ['2026:08:08 23:59:59'] })->{dates})->{bucket}, '2026/20260808', 'M03 no-offset camera-local day');
is(choose([candidate('2026-08-09T00:30:00+09:00'), candidate('2026-08-08T15:30:00Z')])->{bucket},
   '2026/20260809', 'M46 same instant not a fake conflict');
is(choose([candidate('2026-08-09T00:30:00.123+09:00'), candidate('2026-08-08T15:30:00Z')])->{bucket},
   '2026/20260809', 'M46 precision intervals overlap');
is(choose([candidate('2026-08-09T00:30:00+09:00'), candidate('2026-08-08T15:30:00Z','utc',30)])->{bucket},
   '2026/20260809', 'M04 lower fallback never negates main');
is(choose([candidate('invalid'),candidate('2026-08-08T15:30:00Z','utc',30)])->{bucket},
   '2026/20260808', 'M04 illegal primary permits fallback');
is(choose([candidate('2026-08-09T00:30:00+09:00'),candidate('2026-08-07T15:30:00Z')])->{reason},
   'conflicting_capture_date', 'M08 genuine peer conflict');
is(choose([candidate('2026-08-09T00:30:00+09:00'),candidate('2026-08-09T00:30:00','local')])->{reason},
   'ambiguous_date_semantics', 'M08 incomparable semantics cannot invent conflict');
is(choose(meta('video',{ Encoder => ['DJI OsmoAction5 Pro'], CreateDate => ['2026:08:08 20:30:00'] })->{dates})->{bucket},
   '2026/20260809', 'M05 exact DJI evidenced profile');
is(choose(meta('video',{ Encoder => ['DJI Mavic3'], CreateDate => ['2026:08:08 20:30:00'] })->{dates})->{bucket},
   'Undated', 'M05 untested DJI not guessed UTC');
is(choose(meta('video',{ CreateDate => ['2026:08:08 20:30:00'], DeviceModelName => ['ZV-E1'] })->{dates})->{bucket},
   'Undated', 'M04 unproven Sony UTC fallback disabled');
is(choose(meta('video',{ CreationDateValue => ['2026:08:08 23:59:59+09:00'] })->{dates})->{bucket},
   '2026/20260808', 'M06 start date only');
rejects(sub { meta('photo', { GPSLatitude => ['1'] }) }, 'unknown_metadata_field', 'M38 test double cannot inject nonwhitelist field');
is_deeply(meta('photo', { Warning => ['Synthetic parse warning'], DateTimeOriginal => ['2026:08:08 12:00:00'] })->{dates}, [], 'M07 parsing warning yields no trusted date');

my $video = meta('video', { TargetMaterialUmidRef => [$umid], CreationDateValue => ['2026:08:09 00:30:00+09:00'] });
my $xml = meta('xml', { NonRealTimeMetaTargetMaterialUmidRef => [$umid], NonRealTimeMetaCreationDateValue => ['2026:08:10 00:30:00+09:00'] });
my $sidecar = meta('sidecar', {});
my ($dates,$warnings) = group({'v.mp4'=>$video, 'strangeM01.xml'=>$xml, 'v.srt'=>$sidecar});
is($dates->{'strangeM01.xml'}{anchor}, 'v.mp4', 'M09 unique exact UMID joins despite filename');
is($dates->{'strangeM01.xml'}{bucket}, '2026/20260809', 'M04/M09 external date does not override internal');
is($dates->{'v.srt'}{bucket}, '2026/20260809', 'M10 declared same-stem sidecar joins');
my $no_internal = meta('video', {TargetMaterialUmidRef=>[$umid]});
($dates,$warnings) = group({'v.mp4'=>$no_internal,'different.xml'=>$xml});
is($dates->{'v.mp4'}{bucket}, '2026/20260810', 'M04 uniquely linked external XML fallback');
($dates,$warnings) = group({'v.mp4'=>$video,'v2.mp4'=>$video,'strange.xml'=>$xml});
ok($warnings->{'strange.xml'}{ambiguous_pairing}, 'M09 duplicate video UMID ambiguous');
is($dates->{'strange.xml'}{anchor}, 'strange.xml', 'M09 duplicate UMID not arbitrary match');
my $different_xml = meta('xml', { NonRealTimeMetaTargetMaterialUmidRef => ['2'x64] });
($dates,$warnings) = group({'v.mp4'=>$video,'v.xml'=>$different_xml});
is($dates->{'v.xml'}{anchor}, 'v.xml', 'M09 unequal UMID not stem-paired');
($dates,$warnings) = group({'v.mp4'=>$video,'v.mov'=>$video,'v.srt'=>$sidecar});
ok($warnings->{'v.srt'}{ambiguous_pairing}, 'M10 multiple primary candidates not guessed');
my $raw = meta('photo', {DateTimeOriginal=>['2026:08:08 12:00:00']});
my $jpeg = meta('photo', {DateTimeOriginal=>['2026:08:09 12:00:00']});
($dates,$warnings) = group({'p.arw'=>$raw,'p.jpg'=>$raw});
is($dates->{'p.jpg'}{anchor}, 'p.arw', 'M11 RAW priority anchor');
is($dates->{'p.jpg'}{bucket}, '2026/20260808', 'M11 consistent RAW/JPEG grouped');
($dates,$warnings) = group({'p.arw'=>$raw,'p.jpg'=>$jpeg});
is($dates->{'p.jpg'}{reason}, 'conflicting_capture_date', 'M11 RAW/JPEG true conflict');
($dates,$warnings) = group({'v.mp4'=>$video,'v.srt'=>$sidecar}, history('v.mp4','2026/20260801'));
is($dates->{'v.srt'}{bucket}, '2026/20260801', 'M12/M26 late sidecar follows fixed main route');
my $old = { %{history('v.mp4','2026/20260801')}, %{history('v.srt','Undated')} };
rejects(sub {group({'v.mp4'=>$video,'v.srt'=>$sidecar},$old)},'reclassification_required','M13 registered Undated sidecar cannot silently move');
($dates,$warnings) = group({'v.srt'=>$sidecar},history('v.mp4','2026/20260801'));
is($dates->{'v.srt'}{bucket}, 'Undated', 'M47 no historical pairing');
ok($warnings->{'v.srt'}{primary_not_present}, 'M47 primary_not_present observed');
my $identity = OutdoorBackup::MediaDate::Routes::identity($video);
OutdoorBackup::MediaDate::Routes::identity_schema($identity);
ok(!exists($identity->{umid}), 'M15 raw UMID never stored');
my $changed = OutdoorBackup::MediaDate::Routes::identity(meta('video',{TargetMaterialUmidRef=>['2'x64]}));
rejects(sub {OutdoorBackup::MediaDate::Routes::merge_identity($identity,$changed)},'source_slot_reused','M15 changed common signature rejects');
my $enrichment = meta('photo', {DateTimeOriginal=>['2026:08:08 12:00:00'],SubSecTimeOriginal=>['123'],OffsetTimeOriginal=>['+09:00']});
my $enriched = OutdoorBackup::MediaDate::Routes::merge_identity(OutdoorBackup::MediaDate::Routes::identity($raw),OutdoorBackup::MediaDate::Routes::identity($enrichment));
is($enriched->{signatures}{exif_capture_sha256},OutdoorBackup::MediaDate::Routes::identity($raw)->{signatures}{exif_capture_sha256},'M26 offset/subseconds enrichment does not claim reuse');
is_deeply(OutdoorBackup::MediaDate::Routes::merge_identity($identity,undef),$identity,'M26 missing identity preserves historical signatures');
rejects(sub {OutdoorBackup::MediaDate::Path::text("bad\xff")},'UTF-8','M21 nonUTF8 scanner decoder rejects losslessly');
for my $path ("a\nb", "a\tb", '-leading', 'A','a',"\x{e9}","e\x{301}") {
    is(OutdoorBackup::MediaDate::Path::text(OutdoorBackup::MediaDate::Path::bytes($path)),$path,'M20/M36 byte identity preserved');
}
rejects(sub {OutdoorBackup::MediaDate::Scan::check_mounts('/source',"1 0 8:1 / /source ro - ext4 x ro\n2 1 8:1 / /source/sub ro - ext4 x ro\n")},'source_submount','M21 same-dev bind submount rejected');
rejects(sub {OutdoorBackup::MediaDate::Scan::mounts('garbage')},'mountinfo_invalid','M21 malformed mountinfo fails closed');
is_deeply(OutdoorBackup::MediaDate::Scan::mounts("1 0 8:1 / /source\\040space\\011tab\\012newline ro - ext4 x ro\n"),["/source space\ttab\nnewline"],'M21 kernel mount path escapes decoded exactly');

# Integrated planner fixture uses exact Extractor method and schema. The public
# CLI has no injection surface; module test substitutes only extraction I/O.
{
    package SyntheticExtractor;
    sub new { bless { map => $_[1] }, $_[0] }
    sub extract {
        my ($self,$path) = @_;
        $path =~ s{.*/}{};
        my $spec = $self->{map}{$path};
        return OutdoorBackup::MediaDate::Extractor::normalize(@$spec);
    }
}
sub planner_fixture {
    my ($map,$old) = @_;
    my $root = tempdir(CLEANUP=>1);
    mkdir("$root/source",0700) or die $!;
    mkdir("$root/library",0700) or die $!;
    mkdir("$root/work",0700) or die $!;
    for my $name (keys %$map) {open(my $fh,'>',"$root/source/$name") or die $!; print {$fh} 'synthetic'; close($fh) or die $!}
    OutdoorBackup::MediaDate::JSON::write_json("$root/snapshot.json",{version=>1,library_id=>$uuid,source_id=>$source,entries=>$old || {}});
    my $request = {version=>1,source_root=>"$root/source",library_root=>"$root/library",source_id=>$source,route_file=>"$root/snapshot.json",work_dir=>"$root/work",
        library=>{version=>1,library_id=>$uuid,layout=>'date',parser_profile=>'media-date-v1',archive_offset_minutes=>480}};
    my $result = OutdoorBackup::MediaDate::Planner::plan($request,extractor=>SyntheticExtractor->new($map),mountinfo=>"1 0 8:1 / $root/source ro - ext4 x ro\n");
    my $routes = OutdoorBackup::MediaDate::JSON::read_json("$root/work/routes.json");
    return ($result,$routes,$root);
}
my $map = {'a.jpg'=>['photo',{DateTimeOriginal=>['2026:08:07 12:00:00']}],
           'b.jpg'=>['photo',{DateTimeOriginal=>['2026:08:08 12:00:00']}],
           'c.mp4'=>['video',{CreationDateValue=>['2026:08:09 00:30:00+09:00']}],
           'c.srt'=>['sidecar',{}]};
my ($result,$routes,$root) = planner_fixture($map);
is($result->{files_total},4,'M01 helper accepts all current multi-day files');
is_deeply([sort map {$_->{bucket}} values %{$routes->{entries}}],['2026/20260807','2026/20260808','2026/20260809','2026/20260809'],'M01 one view spans three days');
for my $name (keys %$map) {ok(-l "$root/work/view/$routes->{entries}{$name}{target_relpath}",'M01 delivered planner creates controlled leaf symlink')}
rejects(sub {planner_fixture({'v.mp4'=>['video',{TargetMaterialUmidRef=>['2'x64]}]}, {'v.mp4'=>{%{history('v.mp4','Undated')->{'v.mp4'}},recording_identity=>$identity}})},'source_slot_reused','M15 integrated planner rejects reused slot');
rejects(sub {planner_fixture({'v.mp4'=>['video',{CreationDateValue=>['2026:08:09 00:30:00+09:00']}],'v.srt'=>['sidecar',{}]},$old)},'reclassification_required','M13 integrated planner rejects reclassification');
($result,$routes,$root) = planner_fixture({'p.jpg'=>['photo',{DateTimeOriginal=>['2026:08:08 12:00:00']}]},history('p.jpg','Undated'));
is($routes->{entries}{'p.jpg'}{bucket},'Undated','M26 integrated metadata completion cannot move fixed route');
ok(-l "$root/work/view/Undated/$source/p.jpg",'M02 registered file still in current view');

is(choose([candidate('2026-08-08T23:59:59.999999999+09:00')])->{bucket},'2026/20260808','M03 nanosecond precision never rounds into another day');
rejects(sub {OutdoorBackup::MediaDate::Extractor::validate({version=>1,kind=>'photo',dates=>[{field=>'exif_capture',value=>'2026:08:08 12:00:00',priority=>'10',semantics=>'utc',profile=>'invented'}],umid=>undef,warnings=>[]})},'invalid_metadata_date','M03 double must obey normalized semantics/profile/priority contract');
rejects(sub {OutdoorBackup::MediaDate::Extractor::validate({version=>'1',kind=>'photo',dates=>[],umid=>undef,warnings=>[]})},'invalid_metadata_schema','M03 normalized version must be integer');
rejects(sub {OutdoorBackup::MediaDate::Extractor::validate({version=>1,kind=>'other',dates=>[],umid=>undef,warnings=>['invented_warning']})},'invalid_metadata_warning','M38 normalized warnings are white-listed codes');
{
    my $dir=tempdir(CLEANUP=>1);
    mkdir("$dir/lib",0700) or die $!;
    mkdir("$dir/foreign",0700) or die $!;
    symlink("$dir/foreign","$dir/lib/Undated") or die $!;
    require OutdoorBackup::MediaDate::Namespace;
    rejects(sub {OutdoorBackup::MediaDate::Namespace::empty("$dir/lib",$source)},'namespace_component_conflict','M44 never traverse Undated symlink to claim namespace empty');
}

($dates,$warnings) = group({'renamed.xml'=>$xml},{'gone.mp4'=>{%{history('gone.mp4','2026/20260801')->{'gone.mp4'}},recording_identity=>$identity}});
ok($warnings->{'renamed.xml'}{primary_not_present},'M47 historical UMID warns without guessing association');
is($dates->{'renamed.xml'}{anchor},'renamed.xml','M47 independent XML keeps self anchor despite matching historical UMID');

{
    my $dir=tempdir(CLEANUP=>1);
    open(my $fh,'>',"$dir/media") or die $!; print {$fh} 'synthetic'; close($fh) or die $!;
    my $scan=OutdoorBackup::MediaDate::Scan::scan($dir,mountinfo=>"1 0 8:1 / $dir ro - ext4 x ro\n");
    unlink("$dir/media") or die $!;
    rejects(sub {OutdoorBackup::MediaDate::Scan::recheck($scan->{files}{media})},'source_changed','M27 removed source fails before view leaf');
    symlink('/etc/passwd',"$dir/media") or die $!;
    rejects(sub {OutdoorBackup::MediaDate::Scan::recheck($scan->{files}{media})},'source_changed','M27 replacement symlink cannot pass regular-file recheck');
}

# Use a fixed count so a truncated file cannot look like an empty passing suite.
my $overlong = eval { meta('xml',{NonRealTimeMetaCreationDateValue=>['1'x257]}) };
ok($overlong && choose($overlong->{dates})->{bucket} eq 'Undated','M07 overlong malformed metadata keeps ordinary XML Undated');
rejects(sub {meta('photo',{DateTimeOriginal=>[1]})},'invalid_metadata_field','M03 raw double values must match real string-array schema');
for my $count (31,32,33) {
    my $bounded=meta('xml',{NonRealTimeMetaCreationDateValue=>[('2026:08:08 12:00:00Z') x $count]});
    is(choose($bounded->{dates})->{bucket},$count <= 32 ? '2026/20260808' : 'Undated','M07 excessive duplicate fields do not silently discard contradictory peers');
}
plan tests => 84;
