use strict;
use warnings;
use Test::More;
use File::Spec;
use JSON::PP ();
use File::Temp qw(tempdir);
use IO::Socket::INET;
use lib '.';

{
    package TestPrefs;
    sub new { bless { values => {} }, shift }
    sub init { }
    sub get { $_[0]->{values}{$_[1]} }
    sub set { $_[0]->{values}{$_[1]} = $_[2] }

    package Slim::Utils::Prefs;
    my %prefs;
    sub preferences { $prefs{$_[0]} ||= TestPrefs->new }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package Slim::Plugin::Base;
    sub import { }
    sub initPlugin { 1 }
    $INC{'Slim/Plugin/Base.pm'} = __FILE__;

    package Slim::Utils::Timers;
    our @TIMERS;
    sub setTimer { push @TIMERS, [@_] }
    sub killTimers { }
    $INC{'Slim/Utils/Timers.pm'} = __FILE__;

    package Slim::Networking::Select;
    our ($SOCKET, $CALLBACK);
    sub addRead { ($SOCKET, $CALLBACK) = @_ }
    sub removeRead { undef $SOCKET; undef $CALLBACK }
    $INC{'Slim/Networking/Select.pm'} = __FILE__;

    package Slim::Control::Request;
    our @DISPATCH;
    sub addDispatch { push @DISPATCH, [@_] }
    $INC{'Slim/Control/Request.pm'} = __FILE__;

    package main;
    sub WEBUI { 0 }
}

require 'LastFmGuidance/Provider.pm';
$INC{'Plugins/LastFmGuidance/Provider.pm'} = $INC{'LastFmGuidance/Provider.pm'};
require 'LastFmGuidance/PersistenceLog.pm';
$INC{'Plugins/LastFmGuidance/PersistenceLog.pm'} = $INC{'LastFmGuidance/PersistenceLog.pm'};
require 'LastFmGuidance/Plugin.pm';

my $cache = tempdir(CLEANUP => 1);
my (@info, @warnings);
mkdir File::Spec->catdir($cache, 'persistence-errors');
my $pending = File::Spec->catfile($cache, 'persistence-errors', 'info-1-0.json');
open my $pending_out, '>', $pending or die $!;
print {$pending_out} '{"artist":"Pending","returned":1,"stored":1,"excluded_non_library":0}';
close $pending_out;
{
    no warnings 'redefine';
    *Plugins::LastFmGuidance::Provider::_cache_root = sub { $cache };
    *Plugins::LastFmGuidance::Provider::_log_info = sub { push @info, $_[0] };
    *Plugins::LastFmGuidance::Provider::_log_warning = sub { push @warnings, $_[0] };
}
Plugins::LastFmGuidance::Plugin->initPlugin();
is($info[-1], 'Last.fm: stored 1 of 1 similar artists for "Pending" (0 excluded: not in Lyrion library)', 'startup recovers reports left while the server was down');
ok(!-e $pending, 'startup consumes recovered reports');
is(scalar @Slim::Utils::Timers::TIMERS, 0, 'plugin does not poll persistence reports while idle');
my $port_file = File::Spec->catfile($cache, 'persistence-notify-port');
ok(-f $port_file, 'plugin publishes local notification endpoint');
if (-f $port_file && $Slim::Networking::Select::CALLBACK) {
    my $report = File::Spec->catfile($cache, 'persistence-errors', 'info-1-1.json');
    open my $out, '>', $report or die $!;
    print {$out} '{"artist":"Faun","returned":100,"stored":23,"excluded_non_library":77}';
    close $out;
    open my $in, '<', $port_file or die $!;
    my $port = <$in>;
    close $in;
    chomp $port;
    my $sender = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'udp') or die $!;
    $sender->send('wake');
    $Slim::Networking::Select::CALLBACK->($Slim::Networking::Select::SOCKET);
    is($info[-1], 'Last.fm: stored 23 of 100 similar artists for "Faun" (77 excluded: not in Lyrion library)', 'notification logs the existing report message');
    ok(!-e $report, 'notification consumes the report');
    my $error_report = File::Spec->catfile($cache, 'persistence-errors', 'error-1-2.json');
    open my $error_out, '>', $error_report or die $!;
    print {$error_out} '{"error":"exceeded the configured storage limit"}';
    close $error_out;
    $sender->send('wake');
    $Slim::Networking::Select::CALLBACK->($Slim::Networking::Select::SOCKET);
    is($warnings[-1], 'Last.fm background persistence failed: exceeded the configured storage limit', 'notification preserves the existing warning');
    ok(-f File::Spec->catfile($cache, 'persistence-errors', 'last-budget-rejection.json'), 'notification retains the settings-page budget marker');
}
my $shutdown = eval { Plugins::LastFmGuidance::Plugin->shutdownPlugin(); 1 };
ok($shutdown, 'shutdown succeeds without a base shutdown method');
ok(!-e $port_file, 'shutdown removes its notification endpoint');
is_deeply(
    $Slim::Control::Request::DISPATCH[0][0],
    ['lastfmguidance', 'graph', '_action'],
    'plugin registers the background graph-maintenance command',
);

is(Plugins::LastFmGuidance::Plugin->getDisplayName, 'PLUGIN_LASTFMGUIDANCE_NAME', 'plugin publishes localized display name');
my $descriptor = Plugins::LastFmGuidance::Plugin->guidance_provider_descriptor_v1;
is($descriptor->{provider_id}, 'lastfm', 'plugin forwards the public provider descriptor');

{
    package Plugins::LastFmGuidance::GraphJobs;
    sub perform_action {
        return {
            ok => 1,
            status => {
                progress => {
                    database_bytes => 12_345,
                    retained_lastfm_bytes => 6_789,
                    current_artist => 'Seed Artist',
                    finished => JSON::PP::true,
                    cancelled => JSON::PP::true,
                    budget_exhausted => JSON::PP::true,
                },
            },
            graph => {
                state => 'available',
            },
        };
    }
    sub status { return { progress => {} } }
    $INC{'Plugins/LastFmGuidance/GraphJobs.pm'} = __FILE__;

    package GraphCommandRequest;
    sub new { bless { results => {} }, shift }
    sub isNotCommand { 0 }
    sub getParam { 'status' }
    sub addResult { $_[0]->{results}{$_[1]} = $_[2] }
    sub setStatusDone { $_[0]->{done} = 1 }

    package main;
    my $request = GraphCommandRequest->new;
    Plugins::LastFmGuidance::Plugin::_graphCommand($request);
    is($request->{results}{graph_database_bytes}, 12_345,
        'graph command reports physical SQLite storage separately');
    is($request->{results}{graph_bytes}, 12_345,
        'graph command preserves the existing physical-size field');
    is($request->{results}{graph_retained_lastfm_bytes}, 6_789,
        'graph command reports retained Last.fm data separately');
    is($request->{results}{current_artist}, 'Seed Artist',
        'graph command reports the artist currently fetched by the native updater');
    for my $field (qw(finished cancelled budget_exhausted)) {
        is($request->{results}{$field}, 1, "$field is returned as a JSON-safe numeric flag");
        ok(!ref($request->{results}{$field}), "$field does not leak a blessed JSON boolean");
    }
}

{
    no warnings qw(redefine once);
    my @received;
    local *Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1 = sub {
        @received = @_;
        return { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-key' };
    };
    my $policy = { lastfm_artist_level => 75 };
    my $context = { as_of_unix_seconds => 1 };
    my $environment = Plugins::LastFmGuidance::Plugin->guidance_provider_process_environment_v1($policy, $context);
    is_deeply($environment, { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-key' }, 'plugin forwards launch-only environment map');
    is_deeply(\@received, [$policy, $context], 'plugin removes its class invocant before forwarding environment arguments');
}

done_testing;
