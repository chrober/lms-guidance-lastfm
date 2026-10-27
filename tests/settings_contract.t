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
like($template_source, qr/type="number"[^>]+name="pref_artist_result_limit"/,
    'stored similar-artist limit is a numeric input');
unlike($template_source, qr/<select[^>]+name="pref_artist_result_limit"/,
    'stored similar-artist limit is not a fixed choice list');
like($template_source, qr/<input(?=[^>]+name="pref_data_budget_mb")(?=[^>]+max="100")[^>]*>/,
    'retained Last.fm data budget is configurable up to the service limit');
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
like($template_source, qr/id="lastfm-guidance-job-error"[^>]*>\[% graph_job\.error %\]/,
    'a page reload renders a recorded native-start error outside the live fields');
like($template_source, qr/lastfm-guidance-job-error.*result\.error/s,
    'settings page keeps an early native-start error visible without live fields');
like($template_source, qr/lastfm-guidance-graph-section/, 'graph controls have API-key-only conditional visibility');
like($template_source, qr/graph_status\.retained_lastfm_size/,
    'initial graph status renders preformatted retained Last.fm data size');
like($template_source, qr/result\.graph_retained_lastfm_bytes/,
    'live graph status renders retained Last.fm data bytes');
like($template_source, qr/function formatBytes.*1000000.*MB.*1000.*kB/s,
    'byte counts are rendered with human-readable decimal units');
unlike($template_source, qr/lastfm-guidance-job-current-artist/,
    'the current artist is not repeated in a separate status row');
like($template_source, qr/graph_job\.progress\.retained_lastfm_size/,
    'initial graph job status renders preformatted live retained Last.fm data usage');
like($template_source, qr/graph_status\.database_size/,
    'initial graph status retains the separate formatted physical SQLite size');
like($template_source, qr/name="pref_lastfm_artist_level".*id="lastfm-guidance-graph-section"/s,
    'offline graph controls follow the complete default guidance policy');
like($template_source, qr/UNLESS graph_job\.running \|\| graph_job\.paused/,
    'server rendering hides live job details unless maintenance is active');
like($template_source, qr/var hasJob = graphRunning \|\| paused;/,
    'live rendering hides completed job details once maintenance stops');
unlike($template_source, qr/hasJob = [^;\r\n]*result\.start/,
    'a completed job start timestamp does not keep live details visible');

done_testing;
