use strict;
use warnings;

my ($stdout_path, $stderr_path, @command) = @ARGV;
die "Usage: GraphRunner.pl <stdout> <stderr> <program> [args...]\n"
    unless defined $stdout_path && defined $stderr_path && @command;

open STDERR, '>>:raw', $stderr_path
    or die "Cannot open native graph stderr file '$stderr_path': $!\n";
open STDOUT, '>>:raw', $stdout_path
    or die "Cannot open native graph progress file '$stdout_path': $!\n";

exec { $command[0] } @command;
die "Cannot execute native graph command '$command[0]': $!\n";
