package Plugins::LastFmGuidance::PersistenceLog;

use strict;
use warnings;
use File::Spec::Functions qw(catfile);
use JSON::PP qw(decode_json);

sub drain {
    my ($dir, $log) = @_;
    return unless opendir(my $dh, $dir);
    my @files = grep { /^error-\d+-\d+\.json$/ } readdir($dh);
    closedir($dh);
    for my $name (sort @files) {
        my $path = catfile($dir, $name);
        next if -l $path || !-f $path || -s $path > 16384;
        open my $fh, '<:raw', $path or next;
        my $bytes = do { local $/; <$fh> };
        close $fh;
        my $data = eval { decode_json($bytes) };
        next unless ref($data) eq 'HASH' && defined $data->{error};
        my $error = $data->{error};
        $error =~ s/[\r\n\x00-\x1f]+/ /g;
        $error = substr($error, 0, 512);
        eval { $log->('Last.fm background persistence failed: ' . $error); 1 } or next;
        unlink $path;
    }
}

1;
