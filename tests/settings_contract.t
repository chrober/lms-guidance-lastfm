use strict;
use warnings;
use Test::More;
use lib '.';

{
    package TestPrefs;
    sub new { bless { values => {} }, shift }
    sub init {
        my ($self, $defaults) = @_;
        $self->{values}{$_} = $defaults->{$_}
            for grep { !exists $self->{values}{$_} } keys %{$defaults};
    }
    sub get { $_[0]->{values}{$_[1]} }
    sub set { $_[0]->{values}{$_[1]} = $_[2] }

    package Slim::Utils::Prefs;
    my %prefs;
    sub preferences { $prefs{$_[0]} ||= TestPrefs->new }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package Slim::Web::Settings;
    sub import { }
    sub new { bless {}, shift }
    $INC{'Slim/Web/Settings.pm'} = __FILE__;
}

require 'LastFmGuidance/Provider.pm';
$INC{'Plugins/LastFmGuidance/Provider.pm'} = $INC{'LastFmGuidance/Provider.pm'};
require 'LastFmGuidance/Settings.pm';

my $render_params = {};
Plugins::LastFmGuidance::Settings->beforeRender($render_params);
ok(!exists $INC{'Plugins/LastFmGuidance/GraphJobs.pm'},
    'rendering LastMix settings does not load or inspect the offline graph job');

is(Plugins::LastFmGuidance::Settings->name, 'PLUGIN_LASTFMGUIDANCE_NAME', 'provider has its own settings title');
is(Plugins::LastFmGuidance::Settings->page,
    'plugins/LastFmGuidance/settings/lastfmguidance.html',
    'provider owns its separate settings template');

open my $template, '<', 'LastFmGuidance/HTML/EN/plugins/LastFmGuidance/settings/lastfmguidance.html'
    or die "Cannot read settings template: $!";
my $template_source = do { local $/; <$template> };
like($template_source, qr/settings\/footer\.html/, 'settings template includes the standard explicit Save footer');
like($template_source, qr/pref_source/, 'settings page renders the LastMix/API Key source selector');
like($template_source, qr/pref_api_key/, 'settings page contains the conditional API key field');
like($template_source, qr/lastfm-guidance-source/, 'settings page identifies the source selector for conditional visibility');
like($template_source, qr/pref_retrieval_policy/, 'settings page owns the API-key retrieval policy');
like($template_source, qr/pref_storage_scope/, 'settings page owns graph storage scope');
like($template_source, qr/pref_artist_result_limit/, 'settings page owns the stored similar-artist limit');
like($template_source, qr/lastfm-guidance-start/, 'settings page exposes an explicit full graph update action');
like($template_source, qr/lastfmguidance.*graph.*action/s,
    'settings page controls the maintenance job through the plugin JSON-RPC command');
like($template_source, qr/fetch\('\/jsonrpc\.js'/,
    'settings page sends maintenance commands to the LMS JSON-RPC endpoint');
unlike($template_source, qr/fetch\('\[%\s*jsonrpc_url\s*%\]'/,
    'settings page does not depend on an unset template URL');
like($template_source, qr/function setGraphPolling.*setInterval\(refreshGraphStatus/s,
    'settings page owns a reusable live-status polling timer');
like($template_source, qr/function refreshGraphStatus.*graphRefreshInFlight.*finally/s,
    'settings page prevents overlapping polls and releases the guard after errors');
like($template_source, qr/setGraphPolling\([^;]+\);\s*refreshGraphStatus\(\)/s,
    'settings page schedules future polls before the first status request can fail');
like($template_source, qr/data-start=.*graph_job\.started_at.*data-duration=.*graph_job\.duration/s,
    'server-rendered job timing is exposed for immediate local formatting');
like($template_source, qr/toLocaleDateString\(\).*toLocaleTimeString\(\)/s,
    'job start time follows the localized BlissMixer date and time format');
like($template_source, qr/hasError.*result\.error.*hasJob.*hasError/s,
    'settings page keeps an early native-start error visible without a running job');
like($template_source, qr/graph_job\.running.*graph_job\.progress\.phase.*graph_job\.error/s,
    'a page reload also renders a recorded native-start error');
like($template_source, qr/lastfm-guidance-graph-section/, 'graph controls have API-key-only conditional visibility');
like($template_source, qr/graph_status\.retained_lastfm_bytes/,
    'initial graph status renders retained Last.fm data bytes');
like($template_source, qr/result\.graph_retained_lastfm_bytes/,
    'live graph status renders retained Last.fm data bytes');
like($template_source, qr/graph_status\.database_bytes/,
    'initial graph status retains the separate physical SQLite byte count');

done_testing;
