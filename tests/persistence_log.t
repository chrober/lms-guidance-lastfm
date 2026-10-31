use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec::Functions qw(catfile);
require './LastFmGuidance/PersistenceLog.pm';

my $dir = tempdir(CLEANUP => 1);
my $path = catfile($dir, 'error-123-456.json');
open my $out, '>:raw', $path or die $!;
print {$out} '{"error":"database is locked"}';
close $out;
my @logs;
Plugins::LastFmGuidance::PersistenceLog::drain($dir, sub { push @logs, shift });
is_deeply(\@logs, ['Last.fm background persistence failed: database is locked'],
    'background database failure reaches the provider logger');
Plugins::LastFmGuidance::PersistenceLog::drain($dir, sub { push @logs, shift });
is(scalar @logs, 1, 'a handled failure is logged once');
done_testing();
