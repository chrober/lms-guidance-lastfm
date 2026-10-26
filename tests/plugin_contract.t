use strict;
use warnings;
use Test::More;
use File::Spec;
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

    package Slim::Control::Request;
    our @DISPATCH;
    sub addDispatch { push @DISPATCH, [@_] }
    $INC{'Slim/Control/Request.pm'} = __FILE__;

    package main;
    sub WEBUI { 0 }
}

require 'LastFmGuidance/Provider.pm';
$INC{'Plugins/LastFmGuidance/Provider.pm'} = $INC{'LastFmGuidance/Provider.pm'};
require 'LastFmGuidance/Plugin.pm';

Plugins::LastFmGuidance::Plugin->initPlugin();
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
