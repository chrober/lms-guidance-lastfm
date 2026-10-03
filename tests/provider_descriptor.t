use strict;
use warnings;
use Test::More;
use lib '.';

{
    package TestPrefs;
    sub new { bless { values => {} }, shift }
    sub init { }
    sub get { $_[0]->{values}{$_[1]} }
    sub set { $_[0]->{values}{$_[1]} = $_[2] }

    package Slim::Utils::Prefs;
    our $PREFS = TestPrefs->new;
    sub import { }
    sub preferences { return $PREFS }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
}

require 'LastFmGuidance/Provider.pm';

my $descriptor = Plugins::LastFmGuidance::Provider::guidance_provider_descriptor_v1();
is($descriptor->{protocol_version}, 1, 'publishes descriptor protocol v1');
is($descriptor->{provider_id}, 'lastfm', 'publishes stable Last.fm provider ID');
is($descriptor->{display_name}, 'Bliss Guidance: Last.fm', 'publishes the Bliss Guidance display name');
is($descriptor->{settings_uri}, 'plugins/LastFmGuidance/settings/lastfmguidance.html', 'owns a separate provider settings page');
is_deeply($descriptor->{capabilities}, [qw(lastfm_similarity lastfm_acquisition)], 'declares Last.fm similarity and acquisition capabilities');
is_deeply($descriptor->{native_spi}{channels}, {
    similar_track => 'lastfm_track',
    similar_artist => 'lastfm_artist',
}, 'maps Last.fm relations to stable native guidance channels');

my %controls = map { $_->{key} => $_ } @{$descriptor->{controls}};
is_deeply($controls{source}{values}, [qw(lastmix api_key)], 'source selector exposes LastMix and API Key');
is($controls{source}{host_overridable}, 0, 'source selection remains provider-owned');
is($controls{lastfm_track_influence}{factory_default}, 25, 'track guidance defaults to 25 percent');
is($controls{lastfm_artist_mode}{factory_default}, 'target_share', 'artist strategy defaults to target share');
is($controls{lastfm_artist_level}{factory_default}, 75, 'artist guidance defaults to 75 percent');

my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
is($defaults->{source}, 'lastmix', 'LastMix is the provider default source');
is($defaults->{lastfm_track_influence}, 25, 'track default is available before settings are saved');
is($defaults->{lastfm_artist_level}, 75, 'artist default is available before settings are saved');

$Slim::Utils::Prefs::PREFS->set(source => 'api_key');
$Slim::Utils::Prefs::PREFS->set(api_key => 'test-direct-api-key');
my $environment = Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1({}, {});
is_deeply($environment, { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-direct-api-key' }, 'direct mode supplies the API key only as launch environment');
ok(!exists $defaults->{api_key}, 'shared defaults do not expose the stored API key');

{
    package Slim::Utils::PluginManager;
    our @ENABLED;
    sub enabledPlugins { return @ENABLED; }
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;
}

@Slim::Utils::PluginManager::ENABLED = ();
ok(!Plugins::LastFmGuidance::Provider::_lastmix_available(), 'missing LastMix is detected rather than silently switching source');
@Slim::Utils::PluginManager::ENABLED = ('Plugins::LastMix::Plugin');
ok(Plugins::LastFmGuidance::Provider::_lastmix_available(), 'enabled LastMix is detected as the selected source backend');

$Slim::Utils::Prefs::PREFS->set(source => 'lastmix');
is_deeply(
    Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1({ source => 'api_key' }, {}),
    {},
    'a host policy cannot override the provider-owned source and obtain an API key',
);
my $status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
is($status->{reason}, 'native_binary_missing', 'missing native binary is reported before a host can start the provider');

done_testing;
