package Plugins::LastFmGuidance::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Plugins::LastFmGuidance::Provider;

my $prefs = Slim::Utils::Prefs::preferences('plugin.guidancelastfm');
my @PREFS = qw(source api_key lastfm_track_influence lastfm_artist_mode lastfm_artist_level);

sub name { return 'PLUGIN_LASTFMGUIDANCE_NAME'; }
sub page { return 'plugins/LastFmGuidance/settings/lastfmguidance.html'; }
sub prefs { return ($prefs, @PREFS); }

sub beforeRender {
    my ($class, $params) = @_;
    Plugins::LastFmGuidance::Provider::init_preferences();
    $params->{provider_defaults} = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    $params->{provider_status} = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    $params->{lastmix_available} = Plugins::LastFmGuidance::Provider::_lastmix_available() ? 1 : 0;
}

sub handler {
    my ($class, $client, $params) = @_;
    Plugins::LastFmGuidance::Provider::init_preferences();
    my $changed = 0;
    for my $key (@PREFS) {
        my $param = 'pref_' . $key;
        next unless exists $params->{$param};
        $changed = 1;
        my $value = $params->{$param};
        if ($key eq 'source') {
            $value = Plugins::LastFmGuidance::Provider::_source($value);
        }
        elsif ($key eq 'lastfm_artist_mode') {
            $value = Plugins::LastFmGuidance::Provider::_artist_mode($value);
        }
        elsif ($key ne 'api_key') {
            $value = _clamp($key, $value);
        }
        $prefs->set($key, $value);
    }
    if ($changed) {
        my $revision = $prefs->get('settings_revision') || 1;
        $prefs->set('settings_revision', $revision + 1);
    }
    return $class->SUPER::handler($client, $params);
}

sub _clamp {
    my ($key, $value) = @_;
    my $descriptor = Plugins::LastFmGuidance::Provider::guidance_provider_descriptor_v1();
    my ($control) = grep { $_->{key} eq $key } @{$descriptor->{controls}};
    $value = $control->{factory_default} unless defined $value && $value =~ /^\d+$/;
    $value = int($value);
    $value = $control->{minimum} if $value < $control->{minimum};
    $value = $control->{maximum} if $value > $control->{maximum};
    return $value;
}

1;
