package Plugins::LastFmGuidance::LibrarySnapshot;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK);
use JSON::PP qw(encode_json);

sub write_snapshot {
    my ($path) = @_;
    require Slim::Schema;
    my $dbh = Slim::Schema->dbh;
    my $statement = $dbh->prepare(q{
        SELECT DISTINCT contributors.id, contributors.name, contributors.musicbrainz_id
        FROM contributors
        JOIN contributor_track ON contributor_track.contributor = contributors.id
        JOIN tracks ON tracks.id = contributor_track.track
        WHERE COALESCE(tracks.remote, 0) = 0
          AND contributors.name IS NOT NULL
          AND contributors.name != ''
        ORDER BY contributors.id
    });
    $statement->execute();
    my @artists;
    while (my @row = $statement->fetchrow_array()) {
        push @artists, {
            lms_contributor_id => 0 + $row[0],
            name => _unicode_text($row[1], $row[0]),
            artist_mbids => defined $row[2] && length $row[2] ? [$row[2]] : [],
        };
    }
    my $identity_source = join("\n", map {
        join('|', $_->{lms_contributor_id}, $_->{name}, @{$_->{artist_mbids}})
    } @artists);
    my $library_identity = sha256_hex(encode('UTF-8', $identity_source));
    my $generated_at = time();
    my $snapshot = {
        kind => 'lastfm-library-artist-roots-v1',
        snapshot_id => $library_identity . '-' . $generated_at,
        library_identity => $library_identity,
        generated_at => 0 + $generated_at,
        artists => \@artists,
    };
    my $temporary = $path . '.tmp';
    open my $fh, '>', $temporary or die "Cannot write Last.fm artist snapshot: $!";
    binmode $fh;
    print {$fh} encode_json($snapshot);
    close $fh or die "Cannot finish Last.fm artist snapshot: $!";
    rename $temporary, $path or die "Cannot publish Last.fm artist snapshot: $!";
    return $snapshot;
}

sub _unicode_text {
    my ($value, $contributor_id) = @_;
    return $value if utf8::is_utf8($value);
    my $decoded = eval { decode('UTF-8', $value, FB_CROAK) };
    die "Invalid UTF-8 in Lyrion contributor $contributor_id" if $@;
    return $decoded;
}

1;
