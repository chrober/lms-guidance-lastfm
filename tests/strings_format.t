use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $path = File::Spec->catfile($FindBin::Bin, '..', 'LastFmGuidance', 'strings.txt');
open my $strings, '<:raw', $path or die "Cannot read $path: $!";
my $contents = do { local $/; <$strings> };

unlike($contents, qr/\r/, 'strings.txt uses LF line endings accepted by Lyrion string parsing');

done_testing;
