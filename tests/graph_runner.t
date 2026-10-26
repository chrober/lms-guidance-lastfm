use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

my $directory = tempdir(CLEANUP => 1);
my $stdout_path = "$directory/progress.jsonl";
my $stderr_path = "$directory/progress.jsonl.err";
my $runner = 'LastFmGuidance/GraphRunner.pl';

my $exit = system(
    $^X,
    $runner,
    $stdout_path,
    $stderr_path,
    $^X,
    '-e',
    'print STDOUT "progress-event\\n"; print STDERR "native-error\\n";',
);

is($exit, 0, 'detached runner returns the native command exit status');
open my $stdout, '<', $stdout_path or die "Cannot read runner stdout: $!";
is(do { local $/; <$stdout> }, "progress-event\n",
    'detached runner writes native stdout to the progress file');
close $stdout;
open my $stderr, '<', $stderr_path or die "Cannot read runner stderr: $!";
is(do { local $/; <$stderr> }, "native-error\n",
    'detached runner writes native stderr to the error file');
close $stderr;

done_testing;
