use strict;
use warnings;
use Test::More;
require './LastFmGuidance/DeferredPersistence.pm';

my ($scanning, $pending, $alive, $launches, $cancelled, $scheduled, $listener, $unsubscribed) = (0, 0, 0, 0, 0, 0);
my @timers;
my $cleanups = 0;
my $runtime = Plugins::LastFmGuidance::DeferredPersistence->new(
    is_scanning => sub { $scanning }, has_pending => sub { $pending },
    launch => sub { ++$launches; $alive = 1; return bless {}, 'FakeDeferredProcess' },
    subscribe => sub { $listener = shift }, unsubscribe => sub { $unsubscribed++ },
    schedule => sub { ++$scheduled; push @timers, $_[0] },
    cleanup => sub { ++$cleanups },
    on_error => sub { die "unexpected error: @_" },
);
{ package FakeDeferredProcess; sub alive { $alive } sub exit_code { 0 } sub exit_signal { 0 } sub die { ++$cancelled; $alive = 0 } }
$runtime->start;
ok($listener, 'subscribes to scan completion');
is($scheduled, 0, 'no timer while idle');
$scanning = 1; $pending = 1;
$runtime->trigger;
is($launches, 0, 'does not start a drain during a scan');
$scanning = 0; $listener->();
is($launches, 1, 'scan completion starts a pending drain');
is($scheduled, 1, 'only active worker is polled');
$pending = 0; $alive = 0;
shift(@timers)->();
is($scheduled, 1, 'polling stops once the worker finishes');
is($cleanups, 1, 'completed worker request is cleaned up');
$pending = 1; $runtime->trigger;
is($launches, 2, 'new pending work can start another drain');
$scanning = 1;
shift(@timers)->();
is($cancelled, 1, 'a new scan cancels the active drain');
is($cleanups, 2, 'cancelled worker request is cleaned up');
$runtime->stop;
is($unsubscribed, 1, 'shutdown unsubscribes from scan notifications');
my ($start_cancel, @start_timers) = (0);
my $start_runtime = Plugins::LastFmGuidance::DeferredPersistence->new(
    is_scanning => sub { 0 }, has_pending => sub { 1 },
    launch => sub { return bless {}, 'StartScanProcess' },
    subscribe => sub {}, unsubscribe => sub {}, schedule => sub { push @start_timers, $_[0] },
    on_error => sub { die "unexpected error: @_" },
);
{ package StartScanProcess; sub alive { !$start_cancel } sub die { ++$start_cancel } }
$start_runtime->start;
$start_runtime->scan_started;
is($start_cancel, 1, 'a scan-start notification cancels an active drain immediately');
my (@signal_timers, @errors);
my $signal_runtime = Plugins::LastFmGuidance::DeferredPersistence->new(
    is_scanning => sub { 0 }, has_pending => sub { 1 },
    launch => sub { return bless {}, 'SignalledDeferredProcess' },
    subscribe => sub {}, unsubscribe => sub {}, schedule => sub { push @signal_timers, $_[0] },
    on_error => sub { push @errors, $_[0] },
);
{ package SignalledDeferredProcess; sub alive { 0 } sub exit_code { 0 } sub exit_signal { 9 } }
$signal_runtime->start;
shift(@signal_timers)->();
is(scalar @errors, 1, 'signal termination is a failure even when exit code is zero');
is(scalar @signal_timers, 0, 'a signalled worker does not create a retry loop');
done_testing;
