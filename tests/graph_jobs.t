use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use Test::More;
use lib '.';

my $directory = tempdir(CLEANUP => 1);

{
    package Proc::Background;
    our $ALIVE = 1;
    our $WAIT = 0;
    our @ARGS;
    our $OPTIONS;
    our $CAPTURED_KEY;
    sub new {
        my ($class, $options, @args) = @_;
        $OPTIONS = $options;
        @ARGS = @args;
        $CAPTURED_KEY = $ENV{BLISS_GUIDANCE_LASTFM_API_KEY};
        return bless {}, $class;
    }
    sub alive { return $ALIVE }
    sub wait { return $WAIT }
    $INC{'Proc/Background.pm'} = __FILE__;

    package Slim::Music::Import;
    our $SCANNING = 0;
    sub stillScanning { return $SCANNING }
    $INC{'Slim/Music/Import.pm'} = __FILE__;

    package Plugins::LastFmGuidance::Provider;
    our $DIRECTORY = $directory;
    our @LOG;
    our $AVAILABLE = 1;
    our $API_KEY = 'private-test-key';
    our $ARTIST_REFRESH = 0;
    our $EMPTY_REFRESH = 0;
    our $CLEANUP_CAPABLE = 1;
    sub guidance_provider_defaults_v1 {
        return {
            source => 'api_key', retrieval_policy => 'online_with_cache',
            storage_scope => 'all_returned_artists', artist_result_limit => 25,
            data_budget_mb => 100,
            artist_refresh_days => $ARTIST_REFRESH, empty_artist_refresh_days => $EMPTY_REFRESH,
        };
    }
    sub guidance_provider_status_v1 {
        return { available => $AVAILABLE, reason => $AVAILABLE ? '' : 'native_graph_capability_missing',
            version => $CLEANUP_CAPABLE ? '{"artist_graph_cleanup":true}' : '{}' };
    }
    sub _api_key { return $API_KEY }
    sub _program_path { return '/trusted/bliss-guidance-lastfm' }
    sub _graph_store_path { return "$DIRECTORY/lastfm.sqlite" }
    sub _legacy_cache_path { return "$DIRECTORY/lastfm-v1.json" }
    sub _root_snapshot_path { return "$DIRECTORY/roots.json" }
    sub _graph_request_path { return "$DIRECTORY/request.json" }
    sub _graph_progress_path { return "$DIRECTORY/progress.jsonl" }
    sub _graph_cancel_path { return "$DIRECTORY/cancel" }
    sub _log_info { push @LOG, ['info', $_[0]] }
    sub _log_error { push @LOG, ['error', $_[0]] }
    $INC{'Plugins/LastFmGuidance/Provider.pm'} = __FILE__;

    package Plugins::LastFmGuidance::LibrarySnapshot;
    sub write_snapshot {
        my ($path) = @_;
        my $value = {
            kind => 'lastfm-library-artist-roots-v1', snapshot_id => 'one',
            library_identity => 'library', generated_at => time(),
            artists => [{ lms_contributor_id => 1, name => 'Artist', artist_mbids => [] }],
        };
        open my $fh, '>', $path or die $!;
        print {$fh} JSON::PP::encode_json($value);
        close $fh;
        return $value;
    }
    $INC{'Plugins/LastFmGuidance/LibrarySnapshot.pm'} = __FILE__;
}

require 'LastFmGuidance/GraphJobs.pm';
{
    open my $fh, '>:raw', "$directory/progress.jsonl" or die $!;
    print {$fh} encode_json({ message => 'Fetching similar artists for Ukulélé', current_artist => 'Ukulélé' }) . "\n";
    close $fh;
    my $event = Plugins::LastFmGuidance::GraphJobs::_last_progress_event();
    is($event->{current_artist}, 'Ukulélé', 'UTF-8 progress JSON is decoded without mojibake');
}
{
    no warnings qw(redefine once);
    *Plugins::LastFmGuidance::GraphJobs::_read_graph_status = sub {
        return { state => 'ready', artists => 1 };
    };
}

local $ENV{BLISS_GUIDANCE_LASTFM_API_KEY};
$Plugins::LastFmGuidance::Provider::AVAILABLE = 0;
my $unavailable = Plugins::LastFmGuidance::GraphJobs::start_update();
is($unavailable->{error}, 'native_graph_capability_missing',
    'rejects a manual update when the installed native provider lacks graph support');
$Plugins::LastFmGuidance::Provider::AVAILABLE = 1;
$Slim::Music::Import::SCANNING = 1;
my $scanning = Plugins::LastFmGuidance::GraphJobs::start_update();
is($scanning->{error}, 'library_scan_running',
    'does not compete with an active Lyrion library scan');
$Slim::Music::Import::SCANNING = 0;
$Plugins::LastFmGuidance::Provider::API_KEY = '';
my $missing_key = Plugins::LastFmGuidance::GraphJobs::start_update();
is($missing_key->{error}, 'api_key_missing',
    'requires the provider-owned API key before freezing a library snapshot');
$Plugins::LastFmGuidance::Provider::API_KEY = 'private-test-key';
$Plugins::LastFmGuidance::Provider::ARTIST_REFRESH = 30;
$Plugins::LastFmGuidance::Provider::EMPTY_REFRESH = 7;
my $started = Plugins::LastFmGuidance::GraphJobs::start_update();
diag($started->{error}) unless $started->{ok};
ok($started->{ok}, 'starts a provider-owned background update');
is($Proc::Background::CAPTURED_KEY, 'private-test-key',
    'passes the API key only through the child process environment');
ok(!defined $ENV{BLISS_GUIDANCE_LASTFM_API_KEY},
    'does not retain the API key in the LMS process environment');
is_deeply(
    [@Proc::Background::ARGS[2 .. $#Proc::Background::ARGS]],
    [
        "$directory/progress.jsonl",
        "$directory/progress.jsonl.err",
        '/trusted/bliss-guidance-lastfm', 'graph', 'sync', '--request', "$directory/request.json",
    ],
    'passes only trusted output paths and the native graph command to the detached runner',
);
is($Proc::Background::ARGS[0], $^X,
    'starts the detached runner with the same Perl interpreter as LMS');
like($Proc::Background::ARGS[1], qr{(?:^|[\\/])GraphRunner\.pl$},
    'uses the provider-owned detached graph runner');
ok(!exists $Proc::Background::OPTIONS->{stdout} && !exists $Proc::Background::OPTIONS->{stderr},
    'does not ask Proc::Background to reopen LMS tied output handles');
ok(-f "$directory/roots.json", 'freezes the library roots before starting native work');
ok(-f "$directory/request.json", 'publishes a trusted maintenance request');
open my $request_fh, '<', "$directory/request.json" or die $!;
my $request = JSON::PP::decode_json(do { local $/; <$request_fh> });
close $request_fh;
is($request->{budget_bytes}, 100_000_000,
    'passes the configured decimal 100 MB retained-data budget to the native scanner');
is($request->{artist_refresh_days}, 30, 'manual update receives the positive-result refresh target');
is($request->{empty_artist_refresh_days}, 7, 'manual update receives the empty-result refresh target');

my $status = Plugins::LastFmGuidance::GraphJobs::status();
ok($status->{running}, 'reports the child as running');
is($status->{operation}, 'sync', 'reports the active maintenance operation');

my $cancelled = Plugins::LastFmGuidance::GraphJobs::cancel();
ok($cancelled->{ok}, 'accepts cooperative cancellation');
ok(-f "$directory/cancel", 'cancellation is communicated through the trusted marker');

$Proc::Background::ALIVE = 0;
Plugins::LastFmGuidance::GraphJobs::status();
$Proc::Background::ALIVE = 1;
$Proc::Background::WAIT = 1;
my $failed_started = Plugins::LastFmGuidance::GraphJobs::start_update();
ok($failed_started->{ok}, 'a completed job does not block a later update');
open my $error_fh, '>', "$directory/progress.jsonl.err" or die $!;
print {$error_fh} "simulated native failure\n";
close $error_fh;
$Proc::Background::ALIVE = 0;
my $failed_status = Plugins::LastFmGuidance::GraphJobs::status();
is($failed_status->{error}, 'simulated native failure',
    'surfaces a native child failure through provider job status');
is($failed_status->{duration} >= 0, 1,
    'retains a stable duration after the native process exits');

$Proc::Background::WAIT = 0;
$Proc::Background::ALIVE = 1;
my $structured_failure_started = Plugins::LastFmGuidance::GraphJobs::start_update();
ok($structured_failure_started->{ok}, 'starts a job for structured native failure checks');
open my $progress_fh, '>', "$directory/progress.jsonl" or die $!;
print {$progress_fh} encode_json({
    schema_version => 1,
    state => 'failed',
    error => 'duplicate canonical artist identity',
}) . "\n";
close $progress_fh;
$Proc::Background::ALIVE = 0;
my $structured_failure_status = Plugins::LastFmGuidance::GraphJobs::status();
is($structured_failure_status->{error}, 'duplicate canonical artist identity',
    'surfaces a structured native graph failure even when the process wrapper has no exit code');

$Proc::Background::WAIT = 0;
$Proc::Background::ALIVE = 1;
my $polling_started = Plugins::LastFmGuidance::GraphJobs::start_update();
ok($polling_started->{ok}, 'starts a job for graph-status polling checks');
{
    no warnings qw(redefine once);
    my $native_status_queries = 0;
    local *Plugins::LastFmGuidance::GraphJobs::_read_graph_status = sub {
        $native_status_queries++;
        return { state => 'ready', artists => 1 };
    };

    is(
        Plugins::LastFmGuidance::GraphJobs::graph_status()->{state},
        'ready',
        'an explicit graph-status refresh reads the native store status',
    );
    is($native_status_queries, 1, 'the explicit refresh invokes the native status command once');

    Plugins::LastFmGuidance::GraphJobs::perform_action('status');
    Plugins::LastFmGuidance::GraphJobs::perform_action('status');
    is($native_status_queries, 1,
        'live UI polling reuses graph metadata instead of spawning a native status process');

    $Proc::Background::ALIVE = 0;
    Plugins::LastFmGuidance::GraphJobs::perform_action('status');
    is($native_status_queries, 2,
        'job completion refreshes persistent graph metadata exactly once');
    Plugins::LastFmGuidance::GraphJobs::perform_action('status');
    is($native_status_queries, 2,
        'idle UI polling keeps the completed graph metadata cached');
}

$Plugins::LastFmGuidance::Provider::CLEANUP_CAPABLE = 0;
is(Plugins::LastFmGuidance::GraphJobs::start_compact()->{error}, 'native_cleanup_capability_missing',
    'cleanup refuses an older binary that would silently skip repair');
$Plugins::LastFmGuidance::Provider::CLEANUP_CAPABLE = 1;
$Proc::Background::ALIVE = 1;
ok(Plugins::LastFmGuidance::GraphJobs::start_compact()->{ok}, 'starts targeted cleanup with a fresh library snapshot');
open my $compact_fh, '<', "$directory/request.json" or die $!;
my $compact_request = JSON::PP::decode_json(do { local $/; <$compact_fh> });
close $compact_fh;
is($compact_request->{roots_path}, "$directory/roots.json", 'cleanup receives the fresh library snapshot');

done_testing;
