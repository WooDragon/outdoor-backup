use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../files/opt/outdoor-backup/lib";
use Test::More tests => 4;
use OutdoorBackup::MediaDate::Path ();

is(
    OutdoorBackup::MediaDate::Path::uuid('ABCDEF01-2345-6789-ABCD-EF0123456789'),
    'ABCDEF01-2345-6789-ABCD-EF0123456789',
    'uppercase UUID is preserved',
);
is(
    OutdoorBackup::MediaDate::Path::uuid('aBCdEf01-2345-6789-aBcD-eF0123456789'),
    'aBCdEf01-2345-6789-aBcD-eF0123456789',
    'mixed-case UUID is preserved',
);
is(
    OutdoorBackup::MediaDate::Path::uuid('abcdef01-2345-6789-abcd-ef0123456789'),
    'abcdef01-2345-6789-abcd-ef0123456789',
    'lowercase UUID is preserved',
);
eval {
    OutdoorBackup::MediaDate::Path::uuid('abcdef01-2345-6789-abcd-ef01234567890');
    1;
};
like($@, qr/invalid_uuid/, 'invalid UUID shape is rejected');
