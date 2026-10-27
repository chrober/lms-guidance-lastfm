use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;
use lib '.';

{
    package TestLibraryDb;
    sub new { bless {}, shift }
    sub prepare {
        my ($self, $sql) = @_;
        die 'snapshot query must exclude remote tracks' unless $sql =~ /tracks\.remote/;
        return TestLibraryStatement->new([
            [12, 'Artist With MBID', 'artist-mbid-12'],
            [27, 'Name Only Artist', undef],
            [28, Encode::encode('UTF-8', 'Ukulélé club de Paris'), undef],
            [29, 'Björk', undef],
        ]);
    }

    package TestLibraryStatement;
    sub new { bless { rows => $_[1], index => 0 }, $_[0] }
    sub execute { 1 }
    sub fetchrow_array {
        my $self = shift;
        return if $self->{index} >= @{$self->{rows}};
        return @{$self->{rows}[$self->{index}++]};
    }

    package Slim::Schema;
    our $DB = TestLibraryDb->new;
    sub dbh { return $DB }
    $INC{'Slim/Schema.pm'} = __FILE__;
}

require 'LastFmGuidance/LibrarySnapshot.pm';

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/library-artist-roots-v1.json";
my $snapshot = Plugins::LastFmGuidance::LibrarySnapshot::write_snapshot($path);

ok(-f $path, 'publishes the immutable library artist snapshot');
ok(!-e "$path.tmp", 'does not leave a partially written snapshot behind');
is($snapshot->{kind}, 'lastfm-library-artist-roots-v1', 'uses the native snapshot kind');
is_deeply($snapshot->{artists}, [
    { lms_contributor_id => 12, name => 'Artist With MBID', artist_mbids => ['artist-mbid-12'] },
    { lms_contributor_id => 27, name => 'Name Only Artist', artist_mbids => [] },
    { lms_contributor_id => 28, name => 'Ukulélé club de Paris', artist_mbids => [] },
    { lms_contributor_id => 29, name => 'Björk', artist_mbids => [] },
], 'captures stable LMS contributor IDs, names, and optional artist MBIDs');
is(
    $snapshot->{library_identity},
    sha256_hex(encode('UTF-8', "12|Artist With MBID|artist-mbid-12\n27|Name Only Artist\n28|Ukulélé club de Paris\n29|Björk")),
    'library identity is deterministic for the frozen root set',
);

open my $fh, '<', $path or die $!;
my $stored = decode_json(do { local $/; <$fh> });
close $fh;
is_deeply($stored, $snapshot, 'published JSON is the returned frozen snapshot');

done_testing;
